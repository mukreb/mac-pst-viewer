#!/bin/bash
# Builds "PST Viewer.app" into ./dist (requires macOS 13+ with Xcode or the Command Line Tools).
#
#   ./scripts/build-app.sh            # build for this Mac
#   ./scripts/build-app.sh universal  # Apple Silicon + Intel
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/PST Viewer.app"
ARCH_FLAGS=()
if [[ "${1:-}" == "universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compileren (release)…"
swift build -c release --product PSTViewer "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --product PSTViewer "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "▸ App-bundel samenstellen…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PSTViewer" "$APP/Contents/MacOS/PSTViewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Icoon maken…"
TMP="$(mktemp -d)"
if swift scripts/make-icon.swift "$TMP/icon.png" 2>/dev/null; then
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  (icoon overgeslagen)"
fi
rm -rf "$TMP"

echo "▸ Ad-hoc ondertekenen…"
codesign --force --deep --sign - "$APP"

echo "✓ Klaar: $APP"
echo "  Starten:  open \"$APP\""
echo "  Of sleep de app naar /Programma's."
