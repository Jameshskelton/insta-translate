#!/bin/bash
# Build insta-translate.app without Xcode project files.
# Uses swiftc directly (SwiftPM's incremental build silently no-ops on stale
# mtimes — always `rm -rf .build` when building with swift build instead).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-build}
APP="$OUT/insta-translate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
echo "compiling…"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AVFoundation -framework Accelerate -framework Combine \
  Sources/InstaTranslateApp/*.swift -o "$APP/Contents/MacOS/insta-translate"

# App icon: regenerate AppIcon.icns from the source PNG at every build so it
# stays in sync with the artwork.
RES="$APP/Contents/Resources"
mkdir -p "$RES"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
SRC="Resources/IconSource.png"
for spec in "icon_16x16.png 16" "icon_16x16@2x.png 32" "icon_32x32.png 32" \
            "icon_32x32@2x.png 64" "icon_128x128.png 128" "icon_128x128@2x.png 256" \
            "icon_256x256.png 256" "icon_256x256@2x.png 512" \
            "icon_512x512.png 512" "icon_512x512@2x.png 1024"; do
  name=${spec%% *}; size=${spec##* }
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$ICONSET"
echo "app icon: $RES/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>insta-translate</string>
  <key>CFBundleDisplayName</key><string>insta-translate</string>
  <key>CFBundleIdentifier</key><string>local.insta-translate</string>
  <key>CFBundleExecutable</key><string>insta-translate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>insta-translate listens to your voice and translates it on this machine.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST
echo "built $APP"
echo "run:   open $APP"
echo "test:  $APP/Contents/MacOS/insta-translate --text \"Hello, how are you?\""
