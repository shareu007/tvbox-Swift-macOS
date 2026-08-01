#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="tvbox"
CONFIGURATION="Release"
BUILD_DIR="build/ios"
ARCHIVE_PATH="$BUILD_DIR/TVBox.xcarchive"
EXPORT_PATH="$BUILD_DIR/exported"
EXPORT_OPTIONS="Config/Local/ExportOptions.plist"
OUTPUT_IPA="TVBox.ipa"

usage() {
    cat <<'EOF'
用法: ./package_ios.sh [--check]

  --check  只检查 Xcode、iOS 平台和签名配置，不清理或构建产物。
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ 缺少命令: $1" >&2
        exit 1
    fi
}

preflight() {
    require_command xcodebuild
    require_command xcodegen
    require_command plutil
    require_command security

    local destinations
    destinations="$(
        xcodebuild \
            -project tvbox.xcodeproj \
            -scheme "$SCHEME" \
            -showdestinations 2>&1 || true
    )"
    if grep -Eq 'platform:iOS.*error:.*(is not installed|not installed)' <<<"$destinations"; then
        echo "❌ Xcode 的 iOS 平台组件尚未完整安装。" >&2
        echo "   请在 Xcode > Settings > Components 安装 iOS，" >&2
        echo "   或运行: xcodebuild -downloadPlatform iOS" >&2
        return 1
    fi
    if ! grep -q 'platform:iOS' <<<"$destinations"; then
        echo "❌ 当前 Xcode 没有可用的 iOS 构建目标。" >&2
        return 1
    fi

    local build_settings
    build_settings="$(
        xcodebuild \
            -project tvbox.xcodeproj \
            -scheme "$SCHEME" \
            -configuration "$CONFIGURATION" \
            -sdk iphoneos \
            -showBuildSettings 2>/dev/null || true
    )"

    local team_id
    team_id="$(
        awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / && $2 != "" { print $2; exit }' \
            <<<"$build_settings"
    )"
    if [[ -z "$team_id" ]]; then
        echo "❌ 未配置 Apple Developer Team。" >&2
        echo "   请复制 Config/Templates/Signing.example.xcconfig 到" >&2
        echo "   Config/Local/Signing.xcconfig，并填写本机签名信息。" >&2
        return 1
    fi

    local bundle_id
    bundle_id="$(
        awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / && $2 != "" { print $2; exit }' \
            <<<"$build_settings"
    )"
    if [[ -z "$bundle_id" ]]; then
        echo "❌ 未解析到 iOS Bundle Identifier。" >&2
        return 1
    fi
    if [[ "$bundle_id" == "com.tvbox.app" ]]; then
        echo "⚠️  当前仍使用公共示例 Bundle ID；若 App ID 冲突，请在本地签名配置中改为唯一值。"
    fi

    if [[ -f "$EXPORT_OPTIONS" ]]; then
        plutil -lint "$EXPORT_OPTIONS" >/dev/null
        if grep -q 'YOUR_TEAM_ID' "$EXPORT_OPTIONS"; then
            echo "❌ $EXPORT_OPTIONS 仍包含占位 Team ID。" >&2
            return 1
        fi
        echo "✅ 已找到本地 IPA 导出配置。"
    else
        echo "ℹ️  未找到 $EXPORT_OPTIONS；本次只会生成 xcarchive。"
    fi

    local valid_identities
    valid_identities="$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk '/valid identities found/ { print $1; exit }'
    )"
    if [[ "${valid_identities:-0}" == "0" ]]; then
        echo "⚠️  钥匙串暂时没有可用签名证书；Xcode 会尝试从已登录账号自动创建或下载。"
    fi

    echo "✅ iOS 打包预检通过（签名值未输出）。"
}

case "${1:-}" in
    "") ;;
    --check)
        preflight
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

echo "生成最新 Xcode 工程..."
xcodegen generate >/dev/null
preflight

echo "清理 iOS 构建目录..."
rm -rf "$BUILD_DIR"
rm -f "$OUTPUT_IPA"
mkdir -p "$BUILD_DIR"

if [[ "${TVBOX_INCLUDE_LOCAL_CONFIG:-0}" == "1" ]]; then
    echo "⚠️  本次个人构建会包含 Config/Local/TVBoxPresets.json，请勿公开发布产物。"
else
    echo "Release 使用公开空预设，不会把本机接口打入安装包。"
fi

echo "开始构建 iOS Archive（Xcode 自动签名）..."
xcodebuild archive \
    -project tvbox.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    echo "✅ Archive 已生成: $ARCHIVE_PATH"
    echo "   创建 $EXPORT_OPTIONS 后重跑脚本可自动导出 IPA。"
    exit 0
fi

echo "导出 IPA..."
mkdir -p "$EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates

shopt -s nullglob
ipa_files=("$EXPORT_PATH"/*.ipa)
shopt -u nullglob
if (( ${#ipa_files[@]} == 0 )); then
    echo "❌ 导出完成，但没有找到 IPA 文件。" >&2
    exit 1
fi

cp "${ipa_files[0]}" "$OUTPUT_IPA"
echo "✅ 打包完成: $OUTPUT_IPA"
