# QuotaBar

A native macOS menu-bar app for checking AI subscription usage at a glance.
The application is currently packaged as **AIMeter**; its bundle and credential
storage names remain unchanged to preserve existing installations.
Open a centered, translucent overlay without switching away from your current app,
then press **Esc** to dismiss it.

## Features

- Minimal two-column HUD with usage percentages, quota windows, and reset countdowns.
- Green below 70%, yellow at 70–89%, and red at 90% or above.
- Menu-bar access and a configurable global shortcut (default **⌘⇧U**).
- Background polling, refresh on open, and a manual refresh button.
- Settings for provider enablement, credentials, keyboard shortcuts, launch at login,
  and manually tracked subscriptions.
- Existing Pi credentials can connect supported providers without duplicate token entry.

**Project status:** working development build, not a published, notarized release.
The current packaged build is **Apple Silicon (arm64), ad-hoc signed, and not
notarized**. The repository still contains placeholder update-feed URLs.
Licensed under the [MIT License](LICENSE).

## Requirements

- **macOS 15 or later.**
- **Apple Silicon** for the currently packaged binary. An Intel package has not
  been validated; building from source uses your machine's default architecture.
- Existing provider credentials for automatic connection, or an imported token
  where supported. Manual subscriptions do not require provider credentials.
- Building from source requires Git, Swift 6 or later, and Xcode Command Line Tools
  or a compatible Xcode installation. Initial dependency resolution needs internet access.

## Installation

### From a packaged build

There is no configured public download URL yet. If you have a trusted local build
or a package supplied by the maintainer:

1. If a `SHA256SUMS` file is supplied, put it beside the DMG and verify it:
   ```bash
   shasum -a 256 -c SHA256SUMS
   ```
   A matching checksum checks file integrity; it does not establish who produced it.
2. Open `AIMeter-0.1.0.dmg` and drag **AIMeter.app** into **Applications**.
3. Eject the disk image, then launch AIMeter from Applications.
4. Look for the three-bar usage icon in the menu bar. AIMeter has no Dock icon.

The current local package is **not notarized**. macOS may block opening a downloaded
copy. Only if you trust its source, use **System Settings → Privacy & Security →
Open Anyway** when offered, and follow the macOS confirmation prompts. Do not
turn off Gatekeeper globally. For public distribution, use a Developer ID-signed
and notarized package instead.

### From source

Clone the public source repository. If you already have a checkout, use its
existing directory instead.

```bash
git clone https://github.com/techoni3/QuotaBar.git
cd QuotaBar

# Install Apple's Command Line Tools if needed.
xcode-select --install

swift --version
swift build -c release
scripts/make-app.sh release
open dist/AIMeter.app
```

To install your build, quit any running copy first and copy `dist/AIMeter.app` to
`/Applications` or `~/Applications`. Launch the installed copy; avoid running
multiple copies simultaneously.

**SDK troubleshooting:** some Command Line Tools installations lack the SwiftUI
macro plugin required by their newest SDK. If build errors mention `SwiftUIMacros`,
use an installed compatible SDK consistently for building, testing, and packaging:

```bash
# Example only: this path must exist on your machine.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build -c release --sdk "$SDK"
AIMETER_SDK="$SDK" scripts/make-app.sh release
open dist/AIMeter.app
```

See [Build system](docs/build-system.md) for SDK and iCloud-checkout workarounds.

## Usage

- **Open/close the HUD:** click the menu-bar icon or press **⌘⇧U** by default.
  It opens centered on the screen containing the pointer.
- **Dismiss:** press **Esc**, click **×**, or click elsewhere.
- **Refresh:** use the HUD's refresh button; opening the HUD also requests fresh data.
- **Settings:** click the HUD gear or right-click the menu-bar icon → **Settings…**.
- **Enable a provider:** open **Settings → Providers**. Disabled providers remain
  listed there even when hidden from the HUD.
- **Change the shortcut or launch at login:** open **Settings → General**.
- **Manual subscriptions:** add or edit them under **Settings → Manual**.
- **Quit:** right-click the menu-bar icon → **Quit AIMeter**.

The HUD shows only enabled providers with a successful result and a non-empty
usage window. A missing card does not necessarily mean the app is broken: check
its state in Settings. Provider APIs may return connection information without
an actual quota measurement; such a connection is not proof of unlimited usage.

## Providers and credentials

| Provider | Credential source / connection path |
| --- | --- |
| Claude Code | Existing Claude Code Keychain credential, or imported token |
| Codex / ChatGPT | Pi `openai-codex` OAuth → native Codex `auth.json` → imported token |
| OpenCode | OpenCode auth file → Pi `opencode-go` → imported token |
| Antigravity | Local language server → Pi OAuth → Keychain |
| Ollama | Pi cloud key when present; otherwise local daemon |
| GitHub Copilot | Pi `github-copilot` OAuth |
| OpenRouter | Pi `openrouter` API key |
| Manual | User-entered plans and percentages |

Pi's default credential file is `~/.pi/agent/auth.json`; Codex's default is
`~/.codex/auth.json` (`CODEX_HOME` is honored). These files are read-only to AIMeter.
Codex OAuth refreshes are retained in memory, not written back to Pi or Codex.
Usage availability and window shapes depend on the provider and account plan.

### Privacy and security

AIMeter uses credentials to request usage information directly from providers.
User-imported credentials are stored in the macOS Keychain. Usage snapshots are
cached at `~/Library/Application Support/AIMeter/cache.json`; preferences and
manual plans use macOS user defaults. Sparkle checks the configured update feed.

The app is **not sandboxed** and may inspect local processes for Antigravity
connection discovery. Never include credential files, tokens, private signing
keys, or unredacted account details in issues, screenshots, or pull requests.
See [Security guidance](SECURITY.md).

## Development and testing

```bash
swift build
swift test
git diff --check
```

With an SDK override and a temporary test build directory:

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift test --build-path /tmp/aimeter-test-build --sdk "$SDK"
```

Provider tests use synthetic fixtures and request stubs. Keychain integration
tests create and remove dedicated test entries in the local Keychain. Layout
changes also need native app checks: inspect the HUD and every Settings page,
resize Settings, and verify Esc, the shortcut, and provider enablement.

- `Sources/AIMeterCore/` — providers, credentials, models, polling, and caching.
- `Sources/AIMeterApp/` — AppKit lifecycle, SwiftUI HUD and Settings, shortcut handling.
- `Tests/` — core and app regression tests.
- `scripts/` — bundle assembly, signing, assets, and release packaging.
- `docs/` — build notes, provider research, and update-feed metadata.

## Packaging and releases

`scripts/make-app.sh release` creates the local ad-hoc-signed app bundle.
`scripts/release.sh` builds the app, stages signing outside the checkout, creates a
DMG, and generates Sparkle appcast metadata. It requires the maintainer's Sparkle
private signing key at `~/aimeter-sparkle-ed25519.private`; this key must never be
committed or distributed.

```bash
# Maintainer-only local packaging; requires the existing Sparkle signing key.
scripts/release.sh

# Integrity checksum for the current package.
(cd dist && shasum -a 256 AIMeter-0.1.0.dmg > SHA256SUMS)
```

Public releases additionally require Developer ID signing, notarization
credentials, real release/feed URLs, and verified bundle versions. See
[scripts/release.sh](scripts/release.sh) for environment variables.
The [release workflow](.github/workflows/release.yml) is a starting point, not
proof that these prerequisites are configured: its runner still needs secure
Sparkle-key provisioning. Do not publish the current placeholder appcast or
label an ad-hoc build as notarized.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and pull-request guidance.
Use the [GitHub issue tracker](https://github.com/techoni3/QuotaBar/issues) for
ordinary bugs and feature requests. Include macOS version, hardware architecture, reproduction
steps, and redacted screenshots. For vulnerabilities, follow [SECURITY.md](SECURITY.md)
instead of posting sensitive details publicly.

## License

AIMeter is licensed under the [MIT License](LICENSE).
Copyright © 2026 Nitin Sachdev. Dependencies retain their respective upstream licenses.
