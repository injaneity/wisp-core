# iOS App Refactor

This branch reshapes Wisp so an iOS app can build on portable Swift code
without inheriting terminal-only behavior.

## Current Split

- `WispCore` is the iOS/macOS-compatible library surface.
- `wisp` is the macOS CLI wrapper around the existing interactive agent loop.

The CLI keeps process execution, terminal IO, and Codex OAuth file loading.
Those behaviors are intentionally outside `WispCore` because they do not map
cleanly to iOS sandboxing.

## App Model

`WispCore` introduces first-class app objects:

- `WispScratchpadItem`
- `WispWikiNote`
- `WispTask`
- `WispTaskThread`
- `WispTaskThreadMessage`
- `WispAppFacade`

This matches the target product direction: scratchpad capture first, structured
memory second, and task threads as the main work surface.

## Backend Providers

The iOS app now has three user-facing setup modes:

- API key, backed by the OpenAI API and defaulting to `gpt-5.4`.
- llama.cpp, backed by `WispLlama` and an imported on-device GGUF model.
- Tailscale Mac, backed by an OpenAI-compatible `/v1` endpoint running on a
  self-hosted Mac over the user's tailnet.

`WispModelBackend` still supports lower-level remote provider values:

- `codex`
- `openai_compatible`
- `ollama`
- `lmstudio`
- `llamacpp`

For Mac-hosted Gemma-style inference, use Ollama:

```yaml
model:
  provider: "ollama"
  name: "gemma4"
  base_url: "http://localhost:11434/v1"
```

For iOS Simulator, `localhost` points at the Mac running the simulator. For a
physical iPhone, use Tailscale, the Mac/server LAN address, or true on-device
llama.cpp inference.

See `docs/ios-inference-setups.md` for the current app setup modes.

## Next App Layer

The next implementation layer should add a SwiftUI app target or Xcode project
that depends on `WispCore` and owns:

- scratchpad capture screen
- task list screen
- task thread screen
- wiki/note browser
- backend settings screen

The app should call `WispCore` APIs and should not directly invoke the CLI.
