# Contributing to QuotaBar

QuotaBar (currently packaged as AIMeter) is a native macOS SwiftPM project
licensed under the [MIT License](LICENSE).
Read the [README](README.md) for setup and installation. Contributions to this
project are made under the same MIT License.

## Before making a change

- Discuss substantial UI, provider, or credential-flow changes with the maintainer.
- Keep a change focused; describe the problem, intended behavior, and trade-offs.
- Search existing issues when a public issue tracker is available.
- Be respectful and constructive in discussions and reviews.

## Local checks

Run from the repository root:

```bash
swift build
swift test
git diff --check
```

If your Command Line Tools SDK cannot compile SwiftUI macros, follow the
[SDK workaround](docs/build-system.md). Keychain tests use dedicated temporary
test entries; provider tests use synthetic credentials and stubbed requests.

For UI changes, also build and launch the actual app:

```bash
swift build -c release
scripts/make-app.sh release
open dist/AIMeter.app
```

Check all Settings pages at default and minimum window sizes, scrolling,
provider enable/disable recovery, the menu-bar action, the configured shortcut,
Esc dismissal, and accessibility labels. Keep the HUD connected-only.

## Pull requests

Explain:

1. What changed and why.
2. Exact build/test commands and their results.
3. Native UI checks and redacted before/after screenshots for visual changes.
4. Known limitations or deferred work.

Use focused commits and synthetic fixtures. Never commit real credentials,
private signing keys, generated `.build/` output, or local app/DMG artifacts.
Keep Pi and provider credential files read-only. Do not log authorization headers,
access tokens, refresh tokens, or pasted credentials. See [SECURITY.md](SECURITY.md).

Documentation should match current behavior. Avoid claims about notarization,
public downloads, automatic updates, or licensing unless they have been verified.
