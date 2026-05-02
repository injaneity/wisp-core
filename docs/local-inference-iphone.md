# Network Inference From A Physical iPhone

For true on-device inference, use the `llama.cpp` setup in
`docs/ios-inference-setups.md`. This document covers server-backed inference
where the iPhone connects to a model runtime over the network.

The polished local setup uses a small trusted LAN service in front of the model
runtime:

```text
iPhone app -> HTTPS LAN proxy -> Ollama / LM Studio / llama.cpp
```

Direct `http://<mac-ip>:11434` access is fine for internal testing, but the app
should prefer a proxy that provides:

- HTTPS
- bearer-token authentication
- Bonjour advertisement
- health endpoint compatibility through `/v1/models`

## Bonjour Contract

The app discovers local inference servers by browsing:

```text
_wisp-llm._tcp
```

The advertised TXT record should include:

```text
scheme=https
provider=ollama
model=gemma4
path=/v1
auth=bearer
```

For manual testing without a proxy, you can advertise an existing Ollama server
from the Mac:

```bash
dns-sd -R "Wisp Local Gemma" _wisp-llm._tcp local 11434 \
  scheme=http provider=ollama model=gemma4 path=/v1 auth=none
```

Ollama must also bind beyond localhost:

```bash
launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
```

Restart Ollama after changing that setting.

## iOS Info.plist

The app target should declare local-network usage:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Wisp connects to your local inference server to run models on your network.</string>

<key>NSBonjourServices</key>
<array>
  <string>_wisp-llm._tcp</string>
</array>

<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

`NSAllowsLocalNetworking` supports local IP and `.local` URLs. Prefer HTTPS for
the trusted proxy even when this key is present.

## App Integration

Use `WispBonjourBackendBrowser` to discover servers:

```swift
let browser = WispBonjourBackendBrowser()
let servers = await browser.discover(timeoutSeconds: 3)
```

Convert the selected server into a backend:

```swift
let backend = servers[0].modelBackend(authentication: .bearerToken(token))
```

Test connectivity:

```swift
let health = await WispBackendHealthClient().check(backend)
```

Show status using `WispBackendConnectionView` from `WispUI`.
