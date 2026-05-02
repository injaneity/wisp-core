# wisp-core

Core implementation for `wisp`.

## Open Source Status

This repository is open-source under the MIT License.

- License: see [`LICENSE`](LICENSE)
- Contributor terms: see [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Community expectations: see [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- Security reporting: see [`SECURITY.md`](SECURITY.md)
- Notices and trademark guidance: see [`NOTICE`](NOTICE)

## Rights to Use

Under the MIT License, users may use, modify, and distribute this code,
including commercially, subject to preserving the copyright and license notice.

Contributors retain copyright in their contributions and license them to the
project under the repository license through signed-off commits (`git commit
-s`).

## Package Structure

- `WispCore`: iOS/macOS-compatible library with app-facing models,
  markdown rendering, and model backend configuration.
- `WispUI`: SwiftUI components for app-facing backend connection status.
- `wisp`: macOS CLI executable that keeps the existing terminal workflow and
  filesystem/tool execution behavior.

The CLI defaults to the Codex backend with `gpt-5.4`, but `.wisp/config.yaml`
can select a local OpenAI-compatible backend:

```yaml
model:
  provider: "ollama"
  name: "gemma4"
  base_url: "http://localhost:11434/v1"
```

Supported provider values are `codex`, `ollama`, `lmstudio`, `llamacpp`, and
`openai_compatible`. For authenticated OpenAI-compatible servers, set
`api_key_env` to the name of an environment variable containing the bearer
token.

For physical iPhone local inference, see
[`docs/local-inference-iphone.md`](docs/local-inference-iphone.md).

## Development

- Build: `swift build`
- Test: `swift test`
