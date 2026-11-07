#!/bin/bash
# Builds TrigIT.app, signs it with your Developer ID, notarizes it with Apple
# and staples the ticket, so it opens on any Mac without Gatekeeper warnings.
# Result: build/TrigIT.app and build/TrigIT.zip (the one to hand out).
#
# One-time setup: see docs/release.md.
#   TRIGIT_SIGNING_IDENTITY  "Developer ID Application: Your Name (TEAMID)"
#   TRIGIT_NOTARY_PROFILE    keychain profile made with `xcrun notarytool store-credentials`
#                            (default: TrigIT)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TRIGIT_SIGNING_IDENTITY:?Set TRIGIT_SIGNING_IDENTITY to your Developer ID Application identity (see docs/release.md)}"
PROFILE="${TRIGIT_NOTARY_PROFILE:-TrigIT}"
APP=build/TrigIT.app
ZIP=build/TrigIT.zip

scripts/build-app.sh

codesign --force --timestamp --options runtime \
    --entitlements scripts/TrigIT.entitlements \
    --sign "$TRIGIT_SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# Re-zip so the copy handed out carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Signed, notarized and stapled: $APP ($ZIP)"
