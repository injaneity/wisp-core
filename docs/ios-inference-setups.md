# iOS Inference Setups

The iOS demo app presents three setup modes before opening the chat screen.

## API key

Default mode.

- Backend: OpenAI API
- Base URL: `https://api.openai.com/v1`
- Default model: `gpt-5.4`
- Credential: bearer API key entered in the setup form

The app sends a Responses API request first. For OpenAI-compatible servers that
do not implement `/v1/responses`, it falls back to `/v1/chat/completions`.

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
