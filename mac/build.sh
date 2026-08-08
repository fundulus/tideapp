#!/bin/zsh
# Builds Tides.app from Sources/main.swift plus the web app one directory up.
#
# No Xcode project: a single-file Swift app assembled straight into a bundle keeps
# the whole port readable and reproducible. Xcode's command line tools do the work,
# so `xcodebuild` and project files are never involved.
#
#   ./build.sh          build
#   ./build.sh run      build then launch
set -e
cd "$(dirname "$0")"

APP="Tides.app"
NAME="Tides"
BUNDLE_ID="com.drewtalley.tides"
VERSION="1.0"
WEB="../index.html"

[[ -f "$WEB" ]] || { echo "error: $WEB not found"; exit 1; }

echo "==> cleaning"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "==> compiling (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization \
    -target ${arch}-apple-macos12.0 \
    -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers \
    -o "build/${NAME}-${arch}" Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/$NAME" "build/${NAME}-arm64" "build/${NAME}-x86_64"

echo "==> bundling web app"
cp "$WEB" "$APP/Contents/Resources/index.html"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

echo "==> writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Without a usage string macOS will not even offer the app to Location Services,
       so the nearest-station button silently does nothing and the app never appears
       in System Settings. -->
  <key>NSLocationWhenInUseUsageDescription</key><string>$NAME uses your location only to find the nearest tide station. It is never stored or sent anywhere.</string>
  <key>NSLocationUsageDescription</key><string>$NAME uses your location only to find the nearest tide station. It is never stored or sent anywhere.</string>
  <key>NSHumanReadableCopyright</key><string>Tide predictions from NOAA CO-OPS and CICESE-derived harmonics. Not for navigation.</string>
$( [[ -f Resources/AppIcon.icns ]] && echo "  <key>CFBundleIconFile</key><string>AppIcon</string>" )
</dict>
</plist>
PLIST

echo "==> signing (ad-hoc, local use)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (unsigned; still runs locally)"

rm -rf build
SIZE=$(du -sh "$APP" | cut -f1)
echo "==> built $APP ($SIZE)"

if [[ "$1" == "run" ]]; then
  echo "==> launching"
  open "$APP"
fi
