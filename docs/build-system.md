# Build system

## Decision: SwiftPM-only build (no Xcode dependency in dev)

The dev machine used to build AIMeter has **macOS Command Line Tools only**
(`swift 6.3.3`); full Xcode is not installed, so `xcodebuild` and `xcodegen`
are unavailable. The whole project therefore builds with `swift build` /
`swift test` under SwiftPM (`swift-tools-version: 6.0`).

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