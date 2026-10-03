#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -t prismtranslate-ollama-tests)"
trap 'rm -f "$BIN"' EXIT

xcrun swiftc -parse-as-library \
  -framework SwiftUI \
  -framework Combine \
  "$ROOT/PrismTranslate/AppSettings.swift" \
  "$ROOT/PrismTranslate/OllamaClient.swift" \
  "$ROOT/Tests/OllamaClientTests.swift" \
  -o "$BIN"

"$BIN"
