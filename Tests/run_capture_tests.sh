#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t prismtranslate-capture-tests)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/CaptureTests.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.prismtranslate.capture-tests</string>
<key>CFBundleExecutable</key><string>CaptureTests</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

SOURCES=()
for source in "$ROOT"/PrismTranslate/*.swift; do
  [[ "$(basename "$source")" == "Main.swift" ]] || SOURCES+=("$source")
done
xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework Combine -framework Vision -framework ScreenCaptureKit \
  "${SOURCES[@]}" "$ROOT/Tests/CaptureSelectionTests.swift" \
  -o "$APP/Contents/MacOS/CaptureTests"

"$APP/Contents/MacOS/CaptureTests" "${1:-$TEST_DIR/evidence}"
