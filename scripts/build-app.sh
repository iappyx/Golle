#!/bin/bash
# Builds Golle.app into ./build. Usage: scripts/build-app.sh [debug|release] [--run]
# No Xcode needed: the Command Line Tools are enough.
#
# VERSION overrides the app version; the release workflow sets it from the git tag (v1.2.3 -> 1.2.3).
# Without it, the version in Resources/Info.plist is used.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Golle"

APP=build/Golle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Golle"
if [ "$CONFIG" = "release" ]; then
  # Drop the debug symbol table: it embeds absolute build paths, which on a developer machine
  # include the macOS user name.
  strip -S "$APP/Contents/MacOS/Golle"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
# Golle's own license, shown in About Golle.
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
else
  echo "note: Resources/AppIcon.icns missing; run scripts/make-icon.sh"
fi
# A stable identity keeps Keychain access (the Touch ID unlock key) across rebuilds
# (create it once with scripts/make-signing-identity.sh); fall back to ad-hoc signing.
IDENTITY="Golle Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "note: signing ad-hoc; run scripts/make-signing-identity.sh for a stable signature"
  codesign --force --sign - "$APP"
fi
# Tell Launch Services about the app, so Finder opens .golledb files with it and shows them as packages.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "Built $APP (version $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"))"

if [ "${2:-}" = "--run" ]; then
  pkill -x Golle 2>/dev/null || true
  open "$APP"
fi
