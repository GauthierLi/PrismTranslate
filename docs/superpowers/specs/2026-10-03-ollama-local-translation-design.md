# Ollama Local Translation Design

## Goal

Add an Ollama-backed local translation provider to PrismTranslate so users can translate with models already installed in local Ollama, without entering an API key, base URL, or model name manually.

## Scope

This feature adds a third provider called `Ollama 本地` alongside the existing OpenAI-compatible and Anthropic-compatible providers. The app discovers locally installed Ollama models through the Ollama HTTP API, lets the user select one of those models, and sends translation requests to Ollama using the app's existing translation prompt.

The feature does not download models, pull missing models, manage Ollama installation, expose a configurable Ollama host, stream partial responses, or change OCR behavior.

## Current Context

PrismTranslate currently stores provider configuration in `AppSettings`, with `ProviderKind` limited to `openai` and `anthropic`. `Translator` initializes from `AppSettings`, checks `apiKey` and `baseURL`, and then posts to either OpenAI-compatible chat completions or Anthropic messages. `SettingsView` always displays editable Base URL, model, and API key fields. `AppDelegate.translate(text:)` blocks translation unless `settings.isConfigured` is true.

The build script compiles every Swift file in `PrismTranslate/*.swift`, so new Swift source files under that directory are automatically included.

## Recommended Approach

Create a small Ollama client boundary and keep Ollama behavior out of the existing OpenAI and Anthropic code paths. `Translator` should add one provider branch for Ollama, while request construction and response parsing live in focused helpers that are easy to test.

Use the local default Ollama origin `http://127.0.0.1:11434`. This matches the user's "local version" requirement and avoids adding any extra input fields. If Ollama is not running, the UI should show a clear refresh error and translation should fail with an actionable local Ollama error message.

## Components

### `ProviderKind`

Add:

- `ollama`
- display name `Ollama 本地`
- default base URL `http://127.0.0.1:11434`
- empty default model

Existing OpenAI and Anthropic defaults remain unchanged.

### `AppSettings`

Persist Ollama's selected model in the existing `model` field, because only one provider is active at a time and the current settings already treat `model` as provider-specific. `applyProviderDefaults()` should set the default Ollama base URL and clear the model until discovery selects one.

`isConfigured` should become provider-aware:

- OpenAI and Anthropic require non-empty API key, base URL, and model.
- Ollama requires only a non-empty model.

### `OllamaClient`

Create a new focused client with:

- `OllamaModel: Identifiable, Hashable`, containing at least `name: String`.
- `listModels() async throws -> [OllamaModel]`, calling `GET /api/tags`.
- `translate(text:source:target:model:) async throws -> String`, calling `POST /api/chat`.
- pure parsing helpers for `/api/tags` and `/api/chat` responses so tests can verify payload handling without requiring Ollama to run.

The `/api/tags` parser should read `models[].name`, trim whitespace, ignore empty names, and return names in server order.

The `/api/chat` parser should read `message.content`, trim whitespace and newlines, and throw an empty-response error if the content is blank.

### `Translator`

Keep the existing system prompt and provider split. Add an Ollama branch that calls `OllamaClient.translate(...)` with `settings.model`.

For Ollama, do not require an API key and do not send an Authorization header. The request body should use:

```json
{
  "model": "<selected model>",
  "stream": false,
  "messages": [
    { "role": "system", "content": "<translation prompt>" },
    { "role": "user", "content": "<source text>" }
  ]
}
```

### `SettingsView`

When the selected provider is Ollama:

- Hide the Base URL text field.
- Hide the API Key field.
- Replace the free-form model text field with a picker populated from discovered Ollama models.
- Add a `刷新模型` button.
- Show loading, error, and empty-list states clearly.
- Disable test translation until a model is selected.

When models refresh:

- Preserve the existing selected model if it still appears.
- Otherwise select the first discovered model.
- If no models are discovered, clear `settings.model`.

When the selected provider is OpenAI or Anthropic, preserve the existing Base URL, model text field, API key field, and protocol help copy.

### `AppDelegate`

Refresh Ollama models opportunistically:

- On launch, if the active provider is Ollama.
- When opening settings.
- When changing provider to Ollama.

Keep translation flow unchanged except for the provider-aware `isConfigured` behavior and user-facing configuration error copy.

## Error Handling

Add local Ollama error messages for:

- Ollama is not running or cannot be reached.
- No local Ollama models are installed.
- No Ollama model is selected.
- Ollama returns a non-2xx HTTP response.
- Ollama returns a malformed or empty chat response.

The UI should avoid treating Ollama as "missing API key". If Ollama is selected and unconfigured, the overlay should ask the user to start Ollama and install/select a local model.

## Testing Strategy

Add Swift tests that can run without Ollama:

- Provider configuration: Ollama does not require API key or editable base URL, but does require a selected model.
- `/api/tags` parser: extracts model names from valid JSON, ignores blank names, and handles an empty model list.
- `/api/chat` parser: extracts trimmed `message.content` and rejects empty/malformed responses.
- Ollama chat request body builder: includes `stream: false`, the selected model, and the system/user messages.

Then run the repository build script to verify all Swift sources compile into the app bundle.

## Acceptance Criteria

- Settings offers `Ollama 本地` as a provider.
- Selecting Ollama does not require entering any text fields.
- The app can discover already installed Ollama models from local Ollama.
- The user can choose one discovered Ollama model for translation.
- Translation through Ollama uses the selected model and the existing translation prompt.
- Existing OpenAI-compatible and Anthropic-compatible behavior remains unchanged.
- The app builds successfully through `./build.sh`.

## Open Decisions

None. The first version intentionally uses the default local Ollama host and does not add host configuration.
