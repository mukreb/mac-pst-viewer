#!/bin/bash
# Builds "PST Viewer.app" into ./dist (requires macOS 13+ with Xcode or the Command Line Tools).
#
#   ./scripts/build-app.sh            # build for this Mac
#   ./scripts/build-app.sh universal  # Apple Silicon + Intel
#
# Set SIGN_IDENTITY to a "Developer ID Application: …" certificate in your keychain to sign for
# distribution (hardened runtime + secure timestamp, as notarization requires); then run
# ./scripts/notarize.sh. Without it the app is ad-hoc signed and only runs on this Mac without warnings.
#
# The version is APP_VERSION if set, else the latest `v*` git tag (without the "v"), else the one in
# Resources/Info.plist. The build number is BUILD_NUMBER if set, else the number of commits.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/PST Viewer.app"
ARCH_FLAGS=()
if [[ "${1:-}" == "universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling (release)…"
swift build -c release --product PSTViewer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product PSTViewer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ Assembling app bundle…"
# Assemble and sign in a temporary folder: inside iCloud Drive (or after Finder copies) files get
# extended attributes that make `codesign` fail with "resource fork, Finder information … not allowed".
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/PST Viewer.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/PSTViewer" "$STAGE/Contents/MacOS/PSTViewer"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
VERSION="${APP_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)}"
VERSION="${VERSION#v}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || true)}"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGE/Contents/Info.plist"
fi
if [[ -n "$BUILD" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$STAGE/Contents/Info.plist"
fi
echo "  version $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGE/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$STAGE/Contents/Info.plist"))"
# Localized Info.plist strings; their presence also tells macOS which languages the app supports.
cp -R Resources/*.lproj "$STAGE/Contents/Resources/"

echo "▸ Creating icon…"
if swift scripts/make-icon.swift "$WORK/icon.png" 2>/dev/null; then
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
else
  echo "  (icon skipped)"
fi

xattr -cr "$STAGE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ Signing with \"$SIGN_IDENTITY\"…"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE"
  codesign --verify --strict --verbose=2 "$STAGE"
else
  echo "▸ Ad-hoc signing…"
  codesign --force --deep --sign - "$STAGE"
fi

rm -rf "$APP"
mkdir -p dist
ditto "$STAGE" "$APP"

echo "✓ Done: $APP"
echo "  Launch:  open \"$APP\""
echo "  Or drag the app to /Applications."
