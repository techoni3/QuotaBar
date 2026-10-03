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
  (M5) wraps this in codesign → notarize → DMG.
- **Tests**: this CLT install ships neither the `Testing` nor the `XCTest`
  module, so swift-testing is vendored as an SPM dependency to make
  `swift test` work locally. On machines with full Xcode the dependency is
  redundant (deprecation warnings appear but do not fail the build) and CI
  could drop it later if desired.
- **Full Xcode is only required at M5**: code signing (Developer ID),
  notarization, and the GitHub Actions release run (CI runners have Xcode).
- **Deployment target**: macOS 15.0. Liquid Glass specific APIs
  (`NSGlassEffectView`) are gated behind `#available(macOS 26, *)` with an
  `NSVisualEffectView` `.hudWindow` fallback for 15.

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
