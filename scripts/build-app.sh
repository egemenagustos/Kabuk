#!/bin/bash
# Builds Kabuk.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Kabuk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kabuk" "$BIN/kabuk-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# What's New reads the release notes from inside the app.
cp CHANGELOG.md "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"

# macOS keeps the permissions it granted Kabuk (Files and Folders and the like) only while the
# signature's certificate stays the same. An ad-hoc signature is new with every build, so after
# each update macOS would ask again. scripts/make-signing-cert.sh creates the certificate;
# KABUK_SIGN_IDENTITY picks another one. Without it the build is signed ad hoc.
IDENTITY="${KABUK_SIGN_IDENTITY:-Kabuk Code Signing}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "No \"$IDENTITY\" certificate; signing ad hoc, so macOS will ask for permissions again after this build."
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null
echo "Built $APP"
