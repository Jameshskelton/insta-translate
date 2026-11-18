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
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>insta-translate</string>
  <key>CFBundleDisplayName</key><string>insta-translate</string>
  <key>CFBundleIdentifier</key><string>local.insta-translate</string>
  <key>CFBundleExecutable</key><string>insta-translate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
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
