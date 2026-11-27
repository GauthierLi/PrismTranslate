#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t prismtranslate-ball-tests)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/BallTests.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.prismtranslate.ball-tests</string>
<key>CFBundleExecutable</key><string>BallTests</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

SOURCES=()
for source in "$ROOT"/PrismTranslate/*.swift; do
  [[ "$(basename "$source")" == "Main.swift" ]] || SOURCES+=("$source")
done
xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework Combine -framework Vision -framework ScreenCaptureKit \
  "${SOURCES[@]}" "$ROOT/Tests/BallInteractionTests.swift" "$ROOT/Tests/BallInactiveApplicationTests.swift" \
  -o "$APP/Contents/MacOS/BallTests"

PEER="$TEST_DIR/ForegroundPeer.app"
mkdir -p "$PEER/Contents/MacOS"
cat > "$PEER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.prismtranslate.ball-tests.foreground-peer</string>
<key>CFBundleExecutable</key><string>ForegroundPeer</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cp "$APP/Contents/MacOS/BallTests" "$PEER/Contents/MacOS/ForegroundPeer"

"$APP/Contents/MacOS/BallTests" "${1:-$TEST_DIR/evidence}"
