#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <app-resources-directory>" >&2
    exit 2
fi
TVBOX_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TVBOX_SOURCE_ROOT="${SRCROOT:-$(dirname "${TVBOX_SCRIPT_DIR}")}"
TVBOX_MOBILE_DEST="$1/SpiderGateway"
mkdir -p "${TVBOX_MOBILE_DEST}"
rsync -a --delete "${TVBOX_SOURCE_ROOT}/spider-gateway/src/" "${TVBOX_MOBILE_DEST}/"
cp "${TVBOX_SOURCE_ROOT}/Vendor/MobileNodeRuntime/LICENSE.node.txt" "$1/LICENSE.node.txt"
