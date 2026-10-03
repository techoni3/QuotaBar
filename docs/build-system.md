# Build system

## Decision: SwiftPM-only build (no Xcode dependency in dev)

The dev machine used to build AIMeter has **macOS Command Line Tools only**;
full Xcode is not installed, so `xcodebuild` and `xcodegen` are unavailable.
The project builds with SwiftPM (`swift-tools-version: 6.0`).

- **App shell**: `AIMeterApp` is an executable target that runs `NSApplication`
  directly and sets `NSApplication.activationPolicy(.accessory)`, which is the
  runtime equivalent of `LSUIElement=true` (no Dock icon). This removes the need
  for an Xcode project while developing.
- **Bundling**: `scripts/make-app.sh [release|debug]` assembles a minimal
  `dist/AIMeter.app` (Info.plist with `LSUIElement`, bundle id
  `app.aimeter.macos`, min OS 15.0) from the SwiftPM binary. CI/release
  tooling wraps this in codesign → optional notarization → DMG. Local builds
  use ad-hoc signing; notarization requires separately configured credentials.
- **Tests**: swift-testing is declared as an SPM dependency for toolchain
  compatibility. Provider tests use synthetic fixtures and stubbed requests;
  Keychain integration tests create and clean up dedicated local entries.
- **Public distribution**: Developer ID signing and notarization need the
  appropriate Apple credentials and notarization tooling. Their presence must
  be verified; a successful local ad-hoc build is not a notarized release.
- **Deployment target**: macOS 15.0. The centered overlay uses a borderless,
  non-activating `NSPanel` with `NSVisualEffectView` behind-window blur. Esc or
  the close button dismisses it; opening it does not activate the app.
- **Architecture**: current locally packaged binaries are arm64. SwiftPM builds
  the host architecture by default; Intel/universal release packaging has not
  been validated.

## Command Line Tools SDK compatibility

Some Command Line Tools installs ship the macOS 27 SDK's SwiftUI `@State` as
an external `SwiftUIMacros` macro but do not include that macro plugin. In that
configuration the app target fails to compile even though the core target builds.
When a compatible SDK is installed, use it consistently for build and tests; for
example, this machine has macOS 26.5:

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build -c release --sdk "$SDK"
swift test --build-path /tmp/aimeter-test-build --sdk "$SDK"
AIMETER_SDK="$SDK" scripts/release.sh
```

`AIMETER_SDK` is supported by `scripts/release.sh` and `scripts/make-app.sh`.
The test build path is outside the iCloud-synced checkout because signing its
resource bundles there can fail on file-provider metadata. Bundle assembly asks
SwiftPM for the selected configuration/SDK's binary location, rather than
assuming a particular `.build` layout. Release signing and DMG staging also
stay in `/tmp`; iCloud metadata can invalidate a signature after copying an app
bundle into the checkout.
