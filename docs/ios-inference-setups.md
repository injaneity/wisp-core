# iOS Inference Setups

The iOS app presents three setup modes before opening the chat screen.
It also exposes a Fast Capture shortcut for Action Button and Shortcuts usage.

## API key

Default mode.

- Backend: OpenAI API
- Base URL: `https://api.openai.com/v1`
- Default model: `gpt-5.4`
- Credential: bearer API key entered in the setup form

The app sends a Responses API request first. For OpenAI-compatible servers that
do not implement `/v1/responses`, it falls back to `/v1/chat/completions`.

The setup screen uses a supported-model dropdown for common OpenAI API choices
and keeps a custom model option available for newly released or private models.
Chat and Fast Capture stay disabled until the API key/model combination has
passed the automatic backend health check.

## llama.cpp

Runs directly on the iPhone.

- Runtime: official llama.cpp XCFramework pinned in `Package.swift`
- Model format: `.gguf`
- App flow: import a GGUF model file, then chat with the local model
- Swift module: `WispLlama`
- Runtime wrapper: `WispLlamaLocalGenerator`

The selected model is copied into the app's Application Support directory under
`Wisp/Models`. The first chat request loads the model and creates the llama.cpp
context. Physical iPhone testing matters here because simulator performance and
memory behavior are not representative.

## Tailscale Mac

Runs inference on a Mac or self-hosted machine reachable through the user's
tailnet.

- Network: Tailscale MagicDNS or a tailnet HTTPS name
- Backend shape: OpenAI-compatible HTTP endpoint
- Default model: `gemma4`
- Credential: optional bearer token

Example when Ollama is running on the Mac:

```sh
ollama serve
tailscale serve --https=443 http://127.0.0.1:11434
```

Then use this base URL in the app:

```text
https://<mac-name>.<tailnet-name>.ts.net/v1
```

For llama.cpp server on the Mac, expose the server in the same way and keep the
app base URL rooted at `/v1`.

## Fast Capture and Action Button

The app registers an App Shortcut named `Fast Capture with Wisp`.

Use it from Shortcuts, Siri, Spotlight, or on supported iPhones:

```text
Settings > Action Button > Shortcut > Wisp Local > Fast Capture
```

Fast Capture opens a dedicated capture screen with:

- quick text entry
- speech capture using iOS speech recognition
- the currently selected backend from setup
- a `Continue in Chat` handoff after Wisp responds

For remote backends, shortcut launches first run the same backend health check
and only open Fast Capture after the selected backend is reachable.

The simulator can test the screen through the `Fast Capture` button on setup.
The physical iPhone is required to validate the actual Action Button long-press
and real microphone behavior.
