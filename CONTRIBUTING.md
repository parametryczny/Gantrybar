# Contributing to BambuBar

Thank you for helping improve BambuBar.

## Before opening a change

- search existing issues and pull requests
- keep changes focused and avoid committing printer access codes, real serial numbers or private IP addresses
- use fictional printer data in tests and screenshots

## Build and verify

Requirements: macOS 26 or newer, Swift 6 and Xcode Command Line Tools.

```bash
swift build --disable-sandbox
.build/debug/Gantry --self-test
.build/debug/Gantry --storage-self-test
.build/debug/Gantry --certificate-pin-self-test
```

Run the unit tests (parsers, MQTT codec, discovery) with:

```bash
./scripts/run-tests.sh
```

The script wraps `swift test` and, on Command Line Tools–only machines,
supplies the swift-testing plugin and framework search paths and builds
outside the project tree. With a full Xcode install, plain `swift test` also
works.

To compile and package both storage variants:

```bash
chmod +x scripts/build-app.sh scripts/build-release.sh
./scripts/build-app.sh local
./scripts/build-app.sh keychain
```

The Keychain storage self-test needs an interactive, unlocked login keychain and is therefore intended for local verification rather than CI.

## Pull requests

Describe what changed, why it is useful and how it was tested. Keep UI changes consistent with the compact native macOS design and include screenshots when the appearance changes.

By contributing, you agree that your contribution is licensed under the MIT License used by this project.
