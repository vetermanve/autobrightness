#!/bin/sh
# Builds AutoBrightnessBar.app from the SwiftPM build.
#
# The bundle is not cosmetic: without an Info.plist the system does not treat the
# binary as an application, which costs the LSUIElement behaviour (no Dock icon)
# and makes CoreLocation refuse outright - it will not ask for permission on
# behalf of a process that has no usage description.
#
# Signing is ad-hoc by default, which is enough on your own machine. Handing it
# to someone else needs a Developer ID:
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./build-app.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AutoBrightnessBar.app"
SIGN_ID="${SIGN_ID:--}"

cd "$HERE"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AutoBrightnessBar"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoBrightnessBar"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP" && echo "signed with: $SIGN_ID"

echo "built: $APP"
echo
echo "install: cp -R \"$APP\" /Applications/"
echo "run:     open \"$APP\""
