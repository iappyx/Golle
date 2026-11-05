#!/bin/bash
# Builds a signed, notarized, stapled Golle.zip that other Macs will open without warnings.
#
# One-time setup (needs a paid Apple Developer account):
#   1. Install your "Developer ID Application" certificate in the login keychain.
#   2. Store notarytool credentials:
#        xcrun notarytool store-credentials golle-notary \
#          --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
#
# Usage: scripts/release.sh "Developer ID Application: Your Name (ABCDE12345)" [golle-notary]
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-}"
PROFILE="${2:-golle-notary}"
if [ -z "$IDENTITY" ]; then
  echo "usage: scripts/release.sh \"Developer ID Application: …\" [notary-profile]" >&2
  exit 2
fi

scripts/make-icon.sh
scripts/build-app.sh release >/dev/null
APP=build/Golle.app
ZIP=build/Golle.zip

# The hardened runtime is required for notarization.
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Ready to share: $ZIP"
spctl --assess --type execute --verbose=2 "$APP" || true
