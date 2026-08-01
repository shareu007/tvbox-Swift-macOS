#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="tvbox-macOS"
BUILD_DIR="build/macos"
APP_PATH="${BUILD_DIR}/Release/TVBox.app"
DMG_STAGE="${BUILD_DIR}/dmg-stage"
OUTPUT_DMG="TVBox-macOS.dmg"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ 缺少命令: $1" >&2
        exit 1
    fi
}

verify_universal_binary() {
    local binary="$1"
    local label="$2"
    local architectures
    architectures="$(lipo -archs "$binary")"
    if [[ " ${architectures} " != *" arm64 "* || " ${architectures} " != *" x86_64 "* ]]; then
        echo "❌ ${label} 不是 Universal 2: ${architectures}" >&2
        exit 1
    fi
    echo "✅ ${label}: ${architectures}"
}

for command in xcodebuild xcodegen hdiutil codesign lipo; do
    require_command "$command"
done

echo "执行公开树隐私检查..."
./scripts/audit_public_tree.sh

echo "生成最新 Xcode 工程..."
xcodegen generate >/dev/null

echo "清理 macOS 专用构建目录..."
rm -rf "$BUILD_DIR"
rm -f "$OUTPUT_DMG"
mkdir -p "$BUILD_DIR"

echo "构建 macOS Release（Universal 2）..."
xcodebuild \
    -project tvbox.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    SYMROOT="$(pwd)/${BUILD_DIR}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ 找不到构建产物: $APP_PATH" >&2
    exit 1
fi

if [[ "$(tr -d '[:space:]' < "${APP_PATH}/Contents/Resources/TVBoxPresets.json")" != "[]" ]]; then
    echo "❌ Release App 意外包含了本机数据源预设" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
verify_universal_binary "${APP_PATH}/Contents/MacOS/TVBox" "TVBox 主程序"
verify_universal_binary "${APP_PATH}/Contents/Resources/EmbeddedNode/node" "内置 Node"

mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "TVBox" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$OUTPUT_DMG"
hdiutil verify "$OUTPUT_DMG"

echo "✅ 打包完成: $OUTPUT_DMG"
echo "ℹ️  当前产物为 ad-hoc 签名且未公证；公开分发时 macOS 可能显示 Gatekeeper 提示。"
