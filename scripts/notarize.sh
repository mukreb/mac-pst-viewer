#!/bin/bash
# Notarizes and staples an app built with SIGN_IDENTITY set (see build-app.sh), so Gatekeeper
# opens it on any Mac without warnings.
#
#   ./scripts/notarize.sh ["dist/PST Viewer.app"]
#
# Credentials, the first that is set wins:
#   NOTARY_PROFILE                               a profile saved once with
#                                                `xcrun notarytool store-credentials <name>`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER  an App Store Connect API key (.p8)
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD  your Apple ID with an app-specific password
#                                                (create one at account.apple.com)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/PST Viewer.app}"
[[ -d "$APP" ]] || { echo "✗ $APP not found; run ./scripts/build-app.sh first" >&2; exit 1; }

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n "${APPLE_ID:-}" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  echo "✗ No notarization credentials; set NOTARY_PROFILE, NOTARY_KEY_PATH or APPLE_ID (see the top of this script)" >&2
  exit 1
fi

# Notarization rejects ad-hoc signatures and signatures without the hardened runtime.
# (Read the output first: with pipefail, `grep -q` closing the pipe early would fail the check.)
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
  echo "✗ $APP isn't signed with a Developer ID certificate; build it with SIGN_IDENTITY set" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"

echo "▸ Submitting to Apple's notary service (usually a few minutes)…"
xcrun notarytool submit "$WORK/upload.zip" "${AUTH[@]}" --wait --output-format json > "$WORK/result.json" || true
ID="$(plutil -extract id raw -o - "$WORK/result.json" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "✗ Notarization failed (status: ${STATUS:-unknown})" >&2
  cat "$WORK/result.json" >&2
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

echo "▸ Stapling the ticket…"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "✓ Notarized: $APP"
