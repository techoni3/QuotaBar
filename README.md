# AIMeter

A native macOS HUD app (macOS 15+, Liquid Glass styling) that lists all your AI coding
subscriptions — Claude Code, Codex, Gemini/Antigravity, OpenCode, Ollama, … — and shows
live server-calculated usage / quota windows for each, at a glance.

- Menu bar anchored HUD panel + global hotkey ⌘⇧U
- 60s background polling + refresh on open + manual refresh
- Status: M1 skeleton in progress (this build: menu bar accessory, HUD panel, settings)
- Keychain-first credentials (with one-time import as an alternative)
- Distributed as a signed + notarized DMG via GitHub Releases (App Store variant later)

Status: **spec phase** — see tracker spec `PER-1` for decisions and milestones (M1–M5).

## Building

SPM only (no Xcode project); macOS 15+.

```bash
swift build            # debug
swift test             # 91 fixture/stub tests, no live network
scripts/make-app.sh    # assembles dist/AIMeter.app (ad-hoc signed, for dev)
open dist/AIMeter.app
```

## Releasing (v0.1.0+)

`scripts/release.sh` builds → signs (Developer ID + hardened runtime +
`Support/entitlements.plist`) → notarizes + staples (when tooling + profile are
present) → builds a signed DMG with `hdiutil` (zero deps) → writes the Sparkle
appcast to `docs/aimeter-appcast.xml` with the ed25519 signature.

```bash
# one-time key generation (private key → ~/aimeter-sparkle-ed25519.private,
# NEVER committed; public key → Support/SparklePublicKey.txt)
swift scripts/generate-sparkle-keys.swift

# local dry run (ad-hoc sign, no notarization)
./scripts/release.sh

# real distribution (Developer ID cert in the login keychain + notary profile)
DEVELOPER_ID_IDENTITY="Developer ID Application: Name (TEAMID)" \
AIMETER_NOTARY_PROFILE="my-notary" \
AIMETER_RELEASE_BASE_URL="https://github.com/OWNER/REPO/releases/download/v0.1.0" \
./scripts/release.sh

git tag v0.1.0 && git push origin v0.1.0   # GitHub Actions release.yml signs on the runner
```

CI (`release.yml`) signs/notarizes on tag `v*` using the `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`,
`APPLE_TEAM_ID` (and optional `NOTARYTOOL_PROFILE`) repo secrets, then attaches
the DMG + appcast to the GitHub Release.

Update distribution notes: the placeholder `OWNER/REPO` in `AIMETER_SU_FEED_URL`
is replaced by the real repo URL once pushed, and `docs/aimeter-appcast.xml`
needs to live served from the repo (raw URL is fine for Sparkle).

## Future App Store (MAS) variant

Not sandboxed today — direct Developer ID distribution. A future MAS build
must flip `Support/entitlements.plist` to `com.apple.security.app-sandbox =
true` and accept these degradations (spec §8 / research cross-cutting):

- **No process spawning / inspection** — Antigravity's local-LS discovery
  (`ps`/`lsof`) and Codex's `~/.codex` reads are sandbox-blocked; Antigravity
  falls back to keychain remote OAuth, Codex to imported tokens.
- **No cross-app keychain live-reads** — Claude's *keychain-live* mode needs the
  sandbox keychain-group grant or prompts; the *import* flow works unchanged.
- **No dotfile reads** — `~/.local/share/opencode/auth.json`, `~/.codex/auth.json`
  must come via the Vault import path instead.
- Self-signed TLS to `127.0.0.1` (Antigravity local server) requires an ATS
  exception that MAS review dislikes — the remote OAuth path avoids it.
- Kept sandbox-portable today via injectable paths (`FileCodexAuthReader`,
  `FileOpenCodeTokenSource`) and URLSession injection — see `Sources/AIMeterCore/`.
