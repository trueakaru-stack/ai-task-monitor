#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.3.0-alpha}"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "dist/AI Task Monitor.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "dist/AITaskMonitor-macOS-${VERSION}.dmg" "dist/SHA256SUMS-macOS.txt"
hdiutil create -volname "AI Task Monitor" -srcfolder "$STAGING" -ov -format UDZO "dist/AITaskMonitor-macOS-${VERSION}.dmg"
shasum -a 256 "dist/AITaskMonitor-macOS-${VERSION}.dmg" | sed 's#dist/##' > "dist/SHA256SUMS-macOS.txt"
