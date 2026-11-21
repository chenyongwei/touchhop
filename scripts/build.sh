#!/bin/bash
set -euo pipefail

TOUCHHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOUCHHOP_BUILD="${TOUCHHOP_BUILD_DIR:-$TOUCHHOP_ROOT/build}"
TOUCHHOP_ARCH="${TOUCHHOP_ARCH:-$(uname -m)}"

case "$TOUCHHOP_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $TOUCHHOP_ARCH" >&2; exit 1 ;;
esac

identity_file="$HOME/Library/Application Support/TouchHop/signing-identity"
sign_identity="${TOUCHHOP_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" && -f "$identity_file" ]]; then
  sign_identity="$(cat "$identity_file")"
  if [[ ! "$sign_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "Invalid TouchHop signing certificate fingerprint in $identity_file" >&2
    exit 1
  fi
fi

TOUCHHOP_APP="$TOUCHHOP_BUILD/TouchHop.app"
mkdir -p "$TOUCHHOP_APP/Contents/MacOS" "$TOUCHHOP_APP/Contents/Resources/Licenses"
xcrun swiftc -O -parse-as-library -target "$TOUCHHOP_ARCH-apple-macos14.0" \
  "$TOUCHHOP_ROOT"/Sources/*.swift \
  -o "$TOUCHHOP_APP/Contents/MacOS/TouchHop" \
  -framework AppKit -framework IOKit -framework CoreGraphics \
  -framework ColorSync -framework ApplicationServices -framework Carbon -framework ServiceManagement
cp "$TOUCHHOP_ROOT/Resources/Info.plist" "$TOUCHHOP_APP/Contents/Info.plist"
cp "$TOUCHHOP_ROOT/Resources/TouchHop.icns" "$TOUCHHOP_APP/Contents/Resources/"
for TOUCHHOP_LOCALIZATION in "$TOUCHHOP_ROOT"/Resources/*.lproj; do
  ditto "$TOUCHHOP_LOCALIZATION" "$TOUCHHOP_APP/Contents/Resources/$(basename "$TOUCHHOP_LOCALIZATION")"
  plutil -lint "$TOUCHHOP_LOCALIZATION/Localizable.strings"
done
cp "$TOUCHHOP_ROOT/LICENSE" "$TOUCHHOP_APP/Contents/Resources/Licenses/TouchHop.LICENSE"
cp "$TOUCHHOP_ROOT/third_party/mac-touchscreen-mapper.LICENSE" "$TOUCHHOP_APP/Contents/Resources/Licenses/"
cp "$TOUCHHOP_ROOT/THIRD_PARTY_NOTICES.md" "$TOUCHHOP_APP/Contents/Resources/Licenses/"
plutil -lint "$TOUCHHOP_APP/Contents/Info.plist"
codesign --force --sign "${sign_identity:--}" --identifier io.github.chenyongwei.touchhop "$TOUCHHOP_APP"
codesign --verify --deep --strict "$TOUCHHOP_APP"
printf 'Built %s (%s)\n' "$TOUCHHOP_APP" "$TOUCHHOP_ARCH"
