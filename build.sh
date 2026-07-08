#!/bin/bash
set -euo pipefail

APP_NAME="棱镜翻译"          # bundle / display name (Chinese)
EXE_NAME="PrismTranslate"    # ASCII executable name
BUNDLE_ID="com.prismtranslate.app"
SRC_DIR="ClipTranslate"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET="arm64-apple-macos13.0"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "Compiling..."
xcrun swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  -framework AppKit -framework SwiftUI -framework Combine \
  "$SRC_DIR"/*.swift \
  -o "$MACOS_DIR/$EXE_NAME"

# App icon
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$RES_DIR/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>NSHumanReadableCopyright</key>
    <string>棱镜翻译</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc codesign so the app can run locally.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "codesign skipped"

echo "Built: $APP_DIR"
