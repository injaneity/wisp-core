# iOS Xcode Testing

The repo now includes a minimal iOS host app at `Apps/iOS/WispLocalDemo`.
It exists to exercise the portable `WispCore` and `WispUI` modules in a real
iOS app target with the required local-network and Bonjour plist entries.

## Generate or Refresh the Xcode Project

```sh
xcodegen generate --spec Apps/iOS/project.yml --project Apps/iOS
```

Open `Apps/iOS/WispLocalDemo.xcodeproj` and select the `WispLocalDemo` scheme.

## Simulator

Install a simulator runtime that matches the active Xcode release first. On this
machine, Xcode 26.4.1 reports that the iOS 26.4 platform is missing while only
an iOS 26.3 simulator runtime is available.

Use Xcode > Settings > Components, or:

```sh
xcodebuild -downloadPlatform iOS
```

Then build:

```sh
xcodebuild \
  -project Apps/iOS/WispLocalDemo.xcodeproj \
  -scheme WispLocalDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Physical iPhone

1. Connect the phone by USB.
2. Unlock it and trust the Mac.
3. Enable Developer Mode on the phone if Xcode asks for it.
4. In Xcode, set a signing team for the `WispLocalDemo` target.
5. If the bundle identifier is already taken for the team, change
   `PRODUCT_BUNDLE_IDENTIFIER` in `Apps/iOS/project.yml`, regenerate, and build.

The current bundle identifier is `dev.wisp.localdemo`.

## Inference Flows

The setup screen supports:

- API key: default OpenAI API mode with `gpt-5.4`.
- llama.cpp: import a `.gguf` model and run it directly on the iPhone.
- Tailscale Mac: enter an OpenAI-compatible `/v1` endpoint exposed from a Mac
  through Tailscale.

For a physical iPhone, `localhost` is the phone itself. Use the server LAN host
or Tailscale URL for server-backed inference. For direct llama.cpp inference,
test on device because simulator performance and memory are not representative.

See `docs/ios-inference-setups.md` for setup details.
