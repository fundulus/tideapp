#!/bin/zsh
# Builds the app for the iOS Simulator and optionally installs and launches it.
#
# Same philosophy as the macOS build: one Swift file compiled straight into a bundle,
# no Xcode project to maintain. A real .xcodeproj only becomes necessary for putting
# the app on a physical iPhone or shipping to the App Store, because both need signing
# and provisioning that xcodebuild drives.
#
#   ./build.sh            build only
#   ./build.sh run        build, install into the booted simulator, launch
set -e
cd "$(dirname "$0")"

APP="Fundulus Tides.app"
NAME="Fundulus Tides"                  # what people see on the home screen
EXEC="Tides"                           # the binary inside; short and space-free
# Unchanged by the rename, for the same reason as the Mac build: the bundle id is
# what saved favourites and offline stations hang off.
BUNDLE_ID="com.drewtalley.tides"
VERSION="1.0"
WEB="../index.html"
MIN_IOS="16.0"
DEVICE="${TIDES_SIM:-iPhone 17 Pro}"

[[ -f "$WEB" ]] || { echo "error: $WEB not found"; exit 1; }

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
echo "==> sdk: $(basename "$SDK")"

echo "==> cleaning"
rm -rf "$APP" build
mkdir -p "$APP" build

echo "==> compiling (simulator, arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O \
    -target ${arch}-apple-ios${MIN_IOS}-simulator \
    -sdk "$SDK" \
    -Xclang-linker -isysroot -Xclang-linker "$SDK" \
    -framework UIKit -framework WebKit \
    -o "build/${EXEC}-${arch}" Sources/main.swift
done
lipo -create -output "$APP/$EXEC" "build/${EXEC}-arm64" "build/${EXEC}-x86_64"

echo "==> bundling web app"
cp "$WEB" "$APP/index.html"
if [[ -f Resources/AppIcon60x60@2x.png ]]; then cp Resources/*.png "$APP/"; fi

echo "==> writing Info.plist"
# CFBundleSupportedPlatforms / DTPlatformName must say iPhoneSimulator or simctl
# refuses the bundle. UILaunchScreen must exist or iOS letterboxes the app into a
# small centred box instead of filling the display.
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key>
  <dict><key>UIColorName</key><string></string></dict>
  <key>UIViewControllerBasedStatusBarAppearance</key><true/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>CFBundleIconFiles</key>
  <array>
    <string>AppIcon60x60</string>
    <string>AppIcon76x76</string>
    <string>AppIcon83.5x83.5</string>
    <string>AppIcon40x40</string>
    <string>AppIcon29x29</string>
  </array>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Fundulus Tides uses your location only to find the nearest tide station. It is never stored or sent anywhere.</string>
</dict>
</plist>
PLIST

rm -rf build
echo "==> built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "$1" == "run" ]]; then
  echo "==> booting simulator: $DEVICE"
  UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | sed -E 's/.*\(([-0-9A-F]{36})\).*/\1/')
  [[ -n "$UDID" ]] || { echo "error: simulator '$DEVICE' not found"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  echo "==> installing"
  xcrun simctl install "$UDID" "$APP"
  echo "==> launching"
  xcrun simctl launch "$UDID" "$BUNDLE_ID"
  echo "   udid: $UDID"
fi
