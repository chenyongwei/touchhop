#!/bin/bash
set -euo pipefail

TOUCHHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOUCHHOP_BUILD="${TOUCHHOP_BUILD_DIR:-$TOUCHHOP_ROOT/build}"
TOUCHHOP_BINARY="$TOUCHHOP_BUILD/TouchHop.app/Contents/MacOS/TouchHop"

if [[ ! -x "$TOUCHHOP_BINARY" ]]; then
  "$TOUCHHOP_ROOT/scripts/build.sh"
fi

"$TOUCHHOP_BINARY" --self-test
