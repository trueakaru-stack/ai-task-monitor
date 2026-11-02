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
codesign --force --deep --sign - "dist/AI Task Monitor.app"
codesign --verify --deep --strict --verbose=2 "dist/AI Task Monitor.app"
plutil -lint "dist/AI Task Monitor.app/Contents/Info.plist"
file "dist/AI Task Monitor.app/Contents/MacOS/AITaskMonitor"
