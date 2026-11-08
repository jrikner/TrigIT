#!/bin/bash
# Builds build/TrigIT.app: a universal release build of the TrigIT executable
# in a proper app bundle, ad-hoc signed so it runs on this Mac.
# For a Developer ID signed and notarized build, use sign-and-notarize.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${TRIGIT_BUNDLE_ID:-com.ncoab.trigit}"
# The version people see (TRIGIT_VERSION, default 1.0) and a build number
# that goes up with every commit.
VERSION="${TRIGIT_VERSION:-1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP=build/TrigIT.app

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TrigIT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrigIT"
# The Icon Composer icon (Assets.car for macOS 26, AppIcon.icns for older macOS)
# and the neutral accent colour.
xcrun actool Resources/AppIcon.icon Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist build/icon-partial.plist >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>TrigIT</string>
    <key>CFBundleDisplayName</key><string>TrigIT</string>
    <key>CFBundleExecutable</key><string>TrigIT</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Jonathan Rikner. Licensed under GPL-3.0-or-later.</string>
    <key>NSMicrophoneUsageDescription</key><string>TrigIT reads LTC timecode from an audio input.</string>
    <key>NSLocalNetworkUsageDescription</key><string>TrigIT sends show cues to devices on the local network and receives Art-Net Timecode.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --entitlements scripts/TrigIT.entitlements --options runtime "$APP"
echo "Built $APP"
