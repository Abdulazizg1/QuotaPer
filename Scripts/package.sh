#!/bin/bash
# Builds a universal QuotaPer.app, a zip and a DMG into $OUT (default ./dist)
# Optional: SIGN_ID="Developer ID Application: Name (TEAMID)" for a notarizable build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
OUT="${OUT:-dist}"
APP="$OUT/QuotaPer.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/QuotaPer"

rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaPer"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>QuotaPer</string>
  <key>CFBundleDisplayName</key><string>QuotaPer</string>
  <key>CFBundleIdentifier</key><string>com.quotaper.app</string>
  <key>CFBundleExecutable</key><string>QuotaPer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: runs locally; see README for Gatekeeper
fi

ditto -c -k --keepParent "$APP" "$OUT/QuotaPer-${VERSION}.zip"

# DMG: the app plus a shortcut to /Applications, so users can drag it across.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "QuotaPer" -srcfolder "$STAGE" -ov -format UDZO "$OUT/QuotaPer-${VERSION}.dmg" > /dev/null
rm -rf "${STAGE:?}"
[ -n "${SIGN_ID:-}" ] && codesign --force --timestamp --sign "$SIGN_ID" "$OUT/QuotaPer-${VERSION}.dmg"

echo "Built $APP, $OUT/QuotaPer-${VERSION}.zip and $OUT/QuotaPer-${VERSION}.dmg"
