#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

audit_history=0
if [[ "${1:-}" == "--history" ]]; then
    audit_history=1
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--history]" >&2
    exit 2
fi

fail() {
    echo "privacy audit failed: $1" >&2
    exit 1
}

tracked_private_paths="$(
    git ls-files |
        grep -Ei '(^|/)(Config/Local|IOS-key)(/|$)|(^|/)ExportOptions\.plist$|\.(p8|p12|pfx|mobileprovision|provisionprofile|cer|pem|key|xcarchive|ipa|dmg)$' ||
        true
)"
if [[ -n "${tracked_private_paths}" ]]; then
    echo "${tracked_private_paths}" >&2
    fail "private configuration, signing material, or build artifacts are tracked"
fi

if ! git check-ignore -q Config/Local/TVBoxPresets.json; then
    fail "Config/Local is not ignored"
fi

if [[ "$(tr -d '[:space:]' < Config/Templates/TVBoxPresets.example.json)" != "[]" ]]; then
    fail "the public TVBox preset template must stay empty"
fi

if ! grep -qx 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' Config/Templates/Signing.example.xcconfig; then
    fail "the public signing template must keep the placeholder Team ID"
fi

if ! grep -q '<string>YOUR_TEAM_ID</string>' Config/Templates/ExportOptions.example.plist; then
    fail "the public export template must keep the placeholder Team ID"
fi

if grep -E -n 'security[[:space:]]+(import|unlock-keychain)|source[[:space:]].*secrets' package_ios.sh; then
    fail "the iOS packaging script must not import certificates, unlock keychains, or execute secrets files"
fi

if grep -E -n 'environment\["(SPIDER_GATEWAY_TOKEN|TVBOX_CLOUD_CONFIG)"\][[:space:]]*=' \
    tvbox/Services/EmbeddedSpiderGateway.swift; then
    fail "embedded Gateway secrets must use the anonymous bootstrap pipe, not environment variables"
fi

if grep -E -n 'TVBOX_CLOUD_CONFIG[[:space:]]*:|process\.env\.TVBOX_CLOUD_CONFIG|this\.cloudConfig|stdio\[4\]' \
    spider-gateway/src/catvod-manager.mjs spider-gateway/src/catvod-runner.mjs; then
    fail "third-party CatVod children must never receive cloud credentials"
fi

credential_hits="$(git grep -I -n -E \
    'https?://[^[:space:]"<>]+:[^[:space:]"<>]+@|DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}([^A-Z0-9]|$)|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|github_pat_[0-9A-Za-z_]{20,}|gh[opsu]_[0-9A-Za-z]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}' \
    | grep -Ev 'demo:secret@|user:secret@example\.com' || true)"
if [[ -n "${credential_hits}" ]]; then
    cut -d: -f1 <<<"${credential_hits}" | sort -u >&2
    fail "credential-like content was found in publishable source"
fi

if git grep -I -n -E '/[U]sers/[^/[:space:]]+|/[h]ome/[^/[:space:]]+'; then
    fail "a local absolute home path was found in publishable source"
fi

if (( audit_history == 1 )); then
    historical_private_paths="$(
        git rev-list --objects --all |
            grep -Ei '(^| )([^ ]*/)?(Config/Local|IOS-key)(/|$)|(^| )([^ ]*/)?ExportOptions\.plist$|\.(p8|p12|pfx|mobileprovision|provisionprofile|xcarchive|ipa|dmg)$' ||
            true
    )"
    historical_signing_commits="$(
        git log --all -G 'DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}([^A-Z0-9]|$)' \
            --format='%H' --all-match | sort -u
    )"
    if [[ -n "${historical_private_paths}" || -n "${historical_signing_commits}" ]]; then
        fail "sensitive paths or personal signing identifiers remain reachable in Git history"
    fi
fi

echo "privacy audit passed$([[ ${audit_history} == 1 ]] && printf ' (including history)')"
