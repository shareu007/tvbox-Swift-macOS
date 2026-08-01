#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <app-resources-directory>" >&2
    exit 2
fi

TVBOX_RESOURCES_DIR="$1"
TVBOX_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TVBOX_SOURCE_ROOT="${SRCROOT:-$(dirname "${TVBOX_SCRIPT_DIR}")}"
TVBOX_LOCAL_PRESETS="${TVBOX_SOURCE_ROOT}/Config/Local/TVBoxPresets.json"
TVBOX_PUBLIC_TEMPLATE="${TVBOX_SOURCE_ROOT}/Config/Templates/TVBoxPresets.example.json"
TVBOX_INCLUDE_LOCAL="${TVBOX_INCLUDE_LOCAL_CONFIG:-}"

if [[ -z "${TVBOX_INCLUDE_LOCAL}" ]]; then
    if [[ "${CONFIGURATION:-Debug}" == "Debug" ]]; then
        TVBOX_INCLUDE_LOCAL="1"
    else
        TVBOX_INCLUDE_LOCAL="0"
    fi
fi

mkdir -p "${TVBOX_RESOURCES_DIR}"
if [[ "${TVBOX_INCLUDE_LOCAL}" == "1" && -f "${TVBOX_LOCAL_PRESETS}" ]]; then
    cp "${TVBOX_LOCAL_PRESETS}" "${TVBOX_RESOURCES_DIR}/TVBoxPresets.json"
else
    cp "${TVBOX_PUBLIC_TEMPLATE}" "${TVBOX_RESOURCES_DIR}/TVBoxPresets.json"
fi
