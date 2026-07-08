#!/bin/bash
set -euo pipefail

APP_NAME="棱镜翻译"
APP_DIR="build/$APP_NAME.app"
DMG_NAME="棱镜翻译"
STAGE="build/dmg_stage"
DMG_OUT="build/${DMG_NAME}.dmg"

[ -d "$APP_DIR" ] || { echo "App not built. Run ./build.sh first."; exit 1; }

rm -rf "$STAGE" "$DMG_OUT"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG_OUT" >/dev/null

rm -rf "$STAGE"
echo "DMG: $DMG_OUT"
