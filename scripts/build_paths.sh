#!/bin/bash
# Shared by both packaging scripts. All build and distribution output stays in
# this one tree; environment variables cannot select an alternative location.
TVBOX_REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TVBOX_DERIVED_DATA_PATH="${TVBOX_REPOSITORY_ROOT}/build/DerivedData"
