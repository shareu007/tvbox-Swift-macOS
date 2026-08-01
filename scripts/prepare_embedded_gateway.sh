#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <app-resources-directory> <architectures>" >&2
    exit 2
fi

TVBOX_RESOURCES_DIR="$1"
TVBOX_ARCHITECTURES="$2"
TVBOX_NODE_VERSION="v22.23.1"
TVBOX_NODE_DIST="https://nodejs.org/dist/${TVBOX_NODE_VERSION}"
TVBOX_CACHE_ROOT="${HOME}/Library/Caches/TVBoxBuild/Node/${TVBOX_NODE_VERSION}"
TVBOX_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TVBOX_SOURCE_ROOT="${SRCROOT:-$(dirname "${TVBOX_SCRIPT_DIR}")}"
TVBOX_NODE_DEST="${TVBOX_RESOURCES_DIR}/EmbeddedNode/node"
TVBOX_GATEWAY_DEST="${TVBOX_RESOURCES_DIR}/SpiderGateway"

mkdir -p "${TVBOX_CACHE_ROOT}" "$(dirname "${TVBOX_NODE_DEST}")" "${TVBOX_GATEWAY_DEST}"

node_for_arch() {
    local architecture="$1"
    local distribution_arch
    case "${architecture}" in
        arm64) distribution_arch="arm64" ;;
        x86_64) distribution_arch="x64" ;;
        *) echo "Unsupported macOS architecture: ${architecture}" >&2; exit 1 ;;
    esac

    local archive="node-${TVBOX_NODE_VERSION}-darwin-${distribution_arch}.tar.gz"
    local archive_path="${TVBOX_CACHE_ROOT}/${archive}"
    local extracted="${TVBOX_CACHE_ROOT}/node-${TVBOX_NODE_VERSION}-darwin-${distribution_arch}/bin/node"
    if [[ ! -x "${extracted}" ]]; then
        curl --fail --location --retry 3 --output "${archive_path}.download" "${TVBOX_NODE_DIST}/${archive}"
        curl --fail --location --retry 3 --output "${TVBOX_CACHE_ROOT}/SHASUMS256.txt" "${TVBOX_NODE_DIST}/SHASUMS256.txt"
        local expected
        expected="$(awk -v file="${archive}" '$2 == file { print $1 }' "${TVBOX_CACHE_ROOT}/SHASUMS256.txt")"
        local actual
        actual="$(shasum -a 256 "${archive_path}.download" | awk '{ print $1 }')"
        if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
            echo "Checksum verification failed for ${archive}" >&2
            exit 1
        fi
        mv "${archive_path}.download" "${archive_path}"
        tar -xzf "${archive_path}" -C "${TVBOX_CACHE_ROOT}"
    fi
    echo "${extracted}"
}

read -r -a requested_architectures <<< "${TVBOX_ARCHITECTURES}"
if [[ ${#requested_architectures[@]} -eq 0 ]]; then
    requested_architectures=("$(uname -m)")
fi

node_binaries=()
for architecture in "${requested_architectures[@]}"; do
    node_binaries+=("$(node_for_arch "${architecture}")")
done

if [[ ${#node_binaries[@]} -eq 1 ]]; then
    cp "${node_binaries[0]}" "${TVBOX_NODE_DEST}"
else
    lipo -create "${node_binaries[@]}" -output "${TVBOX_NODE_DEST}"
fi
chmod 755 "${TVBOX_NODE_DEST}"
# Copying or merging Mach-O slices invalidates the upstream Node signature.
# Re-sign the final embedded executable so macOS can launch it from the app bundle.
/usr/bin/codesign --force --sign - --timestamp=none "${TVBOX_NODE_DEST}"
TVBOX_NODE_ROOT="$(dirname "$(dirname "${node_binaries[0]}")")"
cp "${TVBOX_NODE_ROOT}/LICENSE" "$(dirname "${TVBOX_NODE_DEST}")/LICENSE.node.txt"

rsync -a --delete "${TVBOX_SOURCE_ROOT}/spider-gateway/src/" "${TVBOX_GATEWAY_DEST}/"
