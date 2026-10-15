#!/bin/sh
# Builds build/VoxtypeOSD.app from Sources/.
set -eu
cd "$(dirname "$0")"

app=build/VoxtypeOSD.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  -o "$app/Contents/MacOS/VoxtypeOSD" Sources/*.swift

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.mahmoudelsayad.voxtype-osd</string>
  <key>CFBundleName</key><string>VoxtypeOSD</string>
  <key>CFBundleExecutable</key><string>VoxtypeOSD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

mkdir -p "$app/Contents/Resources"
cp rewrite/voxtype-rewrite rewrite/rewrite.py "$app/Contents/Resources/"

# A certificate keeps the Accessibility permission across rebuilds. An ad-hoc signature
# changes with every build, and macOS then drops the permission until it is granted again.
# Set SIGN_IDENTITY to choose a certificate; otherwise the first valid one is used.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/^ *1) [0-9A-F]* "\(.*\)"$/\1/p')}"
identity="${identity:--}"
echo "Signing with: $identity"
codesign --force --sign "$identity" --identifier io.github.mahmoudelsayad.voxtype-osd "$app"
echo "Built $app"
