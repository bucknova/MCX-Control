#!/bin/zsh
# Builds "MC-X Control.app" in this folder. Needs only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
swift build -c release --product MCXControl
BIN="$(swift build -c release --product MCXControl --show-bin-path)/MCXControl"
APP="MC-X Control.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MCXControl"
cp Support/Info.plist "$APP/Contents/Info.plist"
ICONS="$(mktemp -d)/AppIcon.iconset"
swift Support/make-icon.swift "$ICONS"
iconutil -c icns "$ICONS" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP"
echo "Built: $PWD/$APP"
