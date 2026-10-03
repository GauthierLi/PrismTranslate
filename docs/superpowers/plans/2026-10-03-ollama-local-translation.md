# Ollama Local Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** Add a local Ollama translation provider that discovers installed models without manual API input, then build and install the verified app while removing stale PrismTranslate artifacts.

**Architecture:** Add a focused `OllamaClient` for local model discovery, request construction, and response parsing. Extend the existing provider/settings/translator flow with an Ollama branch and share an observable model store between `AppDelegate` and `SettingsView` so discovery refreshes automatically and model selection remains synchronized.

**Tech Stack:** Swift 5, Foundation `URLSession`, SwiftUI, Combine, macOS 13 arm64, shell build scripts.

**Spec:** `docs/superpowers/specs/2026-10-03-ollama-local-translation-design.md`

## Global Constraints

- Ollama uses the fixed local origin `http://127.0.0.1:11434`.
- The app only discovers models already installed in Ollama; it never downloads or pulls models.
- Ollama mode hides Base URL and API Key inputs.
- Existing OpenAI-compatible and Anthropic-compatible request behavior remains unchanged.
- The source repository `/Users/liweikang/Code/PrismTranslate` is preserved.
- Stale installed apps and historical build/output copies are removed only after the new build has compiled successfully.
- Existing local changes in `PrismTranslate/AppDelegate.swift` are preserved.

### Task 1: Add failing Ollama contract tests

**Files:**
- Create: `Tests/OllamaClientTests.swift`
- Create: `Tests/run_ollama_tests.sh`

**Interfaces:**
- Tests consume `OllamaClient.parseModels(data:)`.
- Tests consume `OllamaClient.parseChatResponse(data:)`.
- Tests consume `OllamaClient.makeChatRequest(baseURL:model:systemPrompt:userText:)`.
- Tests consume `AppSettings.isConfigured(provider:apiKey:baseURL:model:)`.

- [ ] **Step 1: Write the failing test harness**

Create a standalone macOS test runner that uses `precondition` assertions and exits nonzero on a failure. Cover:

```swift
let models = try OllamaClient.parseModels(data: Data(#"{"models":[{"name":"gemma3:1b"},{"name":"  "},{"name":"qwen3:8b"}]}"#.utf8))
precondition(models.map(\.name) == ["gemma3:1b", "qwen3:8b"])

let response = try OllamaClient.parseChatResponse(data: Data(#"{"message":{"content":"  你好  "}}"#.utf8))
precondition(response == "你好")

let request = try OllamaClient.makeChatRequest(
    baseURL: "http://127.0.0.1:11434",
    model: "gemma3:1b",
    systemPrompt: "Translate.",
    userText: "Hello"
)
let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
precondition(body["model"] as? String == "gemma3:1b")
precondition(body["stream"] as? Bool == false)

precondition(AppSettings.isConfigured(provider: .ollama, apiKey: "", baseURL: "", model: "gemma3:1b"))
precondition(!AppSettings.isConfigured(provider: .ollama, apiKey: "", baseURL: "", model: ""))
```

- [ ] **Step 2: Add the test command**

`Tests/run_ollama_tests.sh` should compile only the test runner plus the production files it needs, then execute the binary:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -t prismtranslate-ollama-tests)"
trap 'rm -f "$BIN"' EXIT
xcrun swiftc -parse-as-library \
  -framework SwiftUI \
  -framework Combine \
  "$ROOT/PrismTranslate/AppSettings.swift" \
  "$ROOT/Tests/OllamaClientTests.swift" \
  -o "$BIN"
"$BIN"
```

- [ ] **Step 3: Run the tests and verify the expected red state**

Run: `./Tests/run_ollama_tests.sh`

Expected: compilation fails because `OllamaClient`, `ProviderKind.ollama`, and the new `AppSettings.isConfigured(...)` contract do not exist yet.

### Task 2: Implement the Ollama client and provider configuration

**Files:**
- Create: `PrismTranslate/OllamaClient.swift`
- Modify: `PrismTranslate/AppSettings.swift`

**Interfaces:**
- Produces `OllamaModel`, `OllamaError`, `OllamaClient`, and `OllamaModelStore`.
- Produces `ProviderKind.ollama`.
- Produces provider-aware `AppSettings.isConfigured`.

- [ ] **Step 1: Implement model and error types**

Define `OllamaModel` with a stable `name` and `id`, plus localized errors for invalid URL, unreachable service, HTTP failures, malformed responses, empty responses, and missing model selection.

- [ ] **Step 2: Implement pure model parsing**

Implement `OllamaClient.parseModels(data:)` to read `models[].name`, trim whitespace, ignore empty names, and preserve server order.

- [ ] **Step 3: Implement pure response parsing and request construction**

Implement `OllamaClient.parseChatResponse(data:)` and `OllamaClient.makeChatRequest(...)`. The request must target `/api/chat`, set JSON content type, and include `model`, `stream: false`, and system/user messages.

- [ ] **Step 4: Implement async discovery and translation**

Implement `listModels()` with `GET /api/tags` and `translate(text:systemPrompt:model:)` with `POST /api/chat`, using `URLSession.shared`, HTTP status validation, and the pure parsers.

- [ ] **Step 5: Implement the observable model store**

Add an `@MainActor` `OllamaModelStore` that publishes models, loading state, and refresh errors. Its `refresh()` method must return the discovered models so callers can preserve the selected model or choose the first model when the prior selection is unavailable.

- [ ] **Step 6: Extend provider configuration**

Add `.ollama`, its display/default values, an empty default model, provider-aware `isConfigured`, and a pure static configuration helper used by the tests.

- [ ] **Step 7: Run the focused tests and verify green**

Run: `./Tests/run_ollama_tests.sh`

Expected: the contract tests pass.

### Task 3: Connect translation and settings UI

**Files:**
- Modify: `PrismTranslate/Translator.swift`
- Modify: `PrismTranslate/SettingsView.swift`
- Modify: `PrismTranslate/AppDelegate.swift`

**Interfaces:**
- `Translator` consumes `OllamaClient`.
- `SettingsView` consumes `OllamaModelStore`.
- `AppDelegate` owns and refreshes the shared model store.

- [ ] **Step 1: Add the Ollama translator branch**

Make `Translator.translate` require only a selected model for Ollama, preserve the existing system prompt, and call `OllamaClient.translate`. Keep API key and base URL validation for the two remote providers.

- [ ] **Step 2: Make the settings form provider-aware**

Render the existing Base URL/model/API Key fields for OpenAI and Anthropic. Render a discovered-model picker, refresh button, loading/error/empty states, and the local endpoint explanation for Ollama.

- [ ] **Step 3: Keep model selection valid after refresh**

When refresh succeeds, preserve the current selected model if present; otherwise select the first discovered model; clear the selection only when a successful refresh returns no models.

- [ ] **Step 4: Refresh at app lifecycle boundaries**

Refresh Ollama models on launch when Ollama is active, when switching to Ollama, and when opening the settings window. Update the existing configuration error copy so Ollama asks the user to start Ollama/select a model instead of asking for an API key.

- [ ] **Step 5: Build to verify UI/compiler integration**

Run: `./build.sh`

Expected: exit code 0 and a newly generated `build/棱镜翻译.app`.

### Task 4: Update documentation and perform clean installation

**Files:**
- Modify: `README.md`
- Modify: `build.sh` only if the final installation/version metadata needs an explicit update.

- [ ] **Step 1: Document Ollama usage**

Update supported providers, setup steps, and directory structure to mention Ollama model discovery and the fixed local endpoint.

- [ ] **Step 2: Run the complete verification set**

Run:

```bash
./Tests/run_ollama_tests.sh
./build.sh
codesign --verify --deep --strict "build/棱镜翻译.app"
plutil -p "build/棱镜翻译.app/Contents/Info.plist"
```

Expected: tests pass, build exits 0, signature verification exits 0, and the bundle identifier remains `com.prismtranslate.app`.

- [ ] **Step 3: Stop the stale app process**

Quit the running historical PrismTranslate process and verify `pgrep -alf 'PrismTranslate|棱镜翻译'` no longer reports the old executable.

- [ ] **Step 4: Remove stale installed and historical artifacts**

Remove only these stale locations after the new build is verified:

```text
/Applications/棱镜翻译.app
/Users/liweikang/Code/PrismTranslate/build
/Users/liweikang/Documents/Codex/2026-07-07/b/outputs/PrismTranslate
/Users/liweikang/Documents/Codex/2026-07-07/b/outputs/棱镜翻译.app
/Users/liweikang/Documents/Codex/2026-07-07/b/outputs/棱镜翻译.dmg
```

- [ ] **Step 5: Install and launch the new app**

Recreate the source repository `build/` output with `./build.sh`, copy `build/棱镜翻译.app` to `/Applications/棱镜翻译.app`, and launch it with `open "/Applications/棱镜翻译.app"`.

- [ ] **Step 6: Verify the installed app is the new build**

Verify:

```bash
test -x "/Applications/棱镜翻译.app/Contents/MacOS/PrismTranslate"
codesign --verify --deep --strict "/Applications/棱镜翻译.app"
plutil -p "/Applications/棱镜翻译.app/Contents/Info.plist"
pgrep -alf 'PrismTranslate|棱镜翻译'
```

Inspect the running executable path and confirm the process points to `/Applications/棱镜翻译.app`, not the deleted historical output.
