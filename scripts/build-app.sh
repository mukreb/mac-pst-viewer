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
swift build -c release --product PSTViewer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product PSTViewer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ App-bundel samenstellen…"
# Assemble and sign in a temporary folder: inside iCloud Drive (or after Finder copies) files get
# extended attributes that make `codesign` fail with "resource fork, Finder information … not allowed".
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/PST Viewer.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/PSTViewer" "$STAGE/Contents/MacOS/PSTViewer"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

echo "▸ Icoon maken…"
if swift scripts/make-icon.swift "$WORK/icon.png" 2>/dev/null; then
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
else
  echo "  (icoon overgeslagen)"
fi

echo "▸ Ad-hoc ondertekenen…"
xattr -cr "$STAGE"
codesign --force --deep --sign - "$STAGE"

rm -rf "$APP"
mkdir -p dist
ditto "$STAGE" "$APP"

echo "✓ Klaar: $APP"
echo "  Starten:  open \"$APP\""
echo "  Of sleep de app naar /Programma's."
