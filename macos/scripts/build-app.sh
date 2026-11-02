#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf dist
mkdir -p "dist/AI Task Monitor.app/Contents/MacOS" "dist/AI Task Monitor.app/Contents/Resources"

swift build -c release --arch arm64 --arch x86_64
cp ".build/apple/Products/Release/AITaskMonitor" "dist/AI Task Monitor.app/Contents/MacOS/AITaskMonitor"
cp "Info.plist" "dist/AI Task Monitor.app/Contents/Info.plist"
chmod 755 "dist/AI Task Monitor.app/Contents/MacOS/AITaskMonitor"

# Each image comes from the corresponding size-specific Figma frame.
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICONSET="$ICON_TEMP/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "assets/app-icon/icon-16.png" "$ICONSET/icon_16x16.png"
cp "assets/app-icon/icon-32.png" "$ICONSET/icon_16x16@2x.png"
cp "assets/app-icon/icon-32.png" "$ICONSET/icon_32x32.png"
cp "assets/app-icon/icon-64.png" "$ICONSET/icon_32x32@2x.png"
cp "assets/app-icon/icon-128.png" "$ICONSET/icon_128x128.png"
cp "assets/app-icon/icon-256.png" "$ICONSET/icon_128x128@2x.png"
cp "assets/app-icon/icon-256.png" "$ICONSET/icon_256x256.png"
cp "assets/app-icon/icon-512.png" "$ICONSET/icon_256x256@2x.png"
cp "assets/app-icon/icon-512.png" "$ICONSET/icon_512x512.png"
cp "assets/app-icon/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "dist/AI Task Monitor.app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "dist/AI Task Monitor.app"
codesign --verify --deep --strict --verbose=2 "dist/AI Task Monitor.app"
plutil -lint "dist/AI Task Monitor.app/Contents/Info.plist"
file "dist/AI Task Monitor.app/Contents/MacOS/AITaskMonitor"
