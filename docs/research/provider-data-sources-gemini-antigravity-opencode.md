# Research: AIMeter — reading AI-coding usage/quota data for Gemini/Antigravity and OpenCode on macOS

Researched against the best curated implementations: **steipete/CodexBar** (`docs/antigravity.md`, `docs/gemini.md`, `docs/opencode.md`), **robinebers/openusage** (winusage/abuhanna is a fork of this) provider docs and plugins, **Nanako0129/TokenBar** (tokscale-core based, local-log only for these providers), and a working primary-source implementation (`aqua5230/usage` → `loaders/agy_quota_probe.py`, AGPL — read for facts, do not copy code).

---

## TOPIC 1 — Gemini / Antigravity (Google)

### 1a. Gemini CLI coding-plan usage — verdict: **usable endpoint** (OAuth-backed private "Cloud Code" API) ✅ HIGH confidence

Proven by: CodexBar Gemini provider (`docs/gemini.md`), OpenUsage `gemini_cli` plugin (https://openusage.sh/docs/providers/gemini-cli/), and multiple independent implementations.

**Endpoints** (undocumented/private `v1internal` RPCs on Cloud Code Assist):

| Purpose | Request |
|---|---|
| Tier/plan discovery | `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` — body `{"metadata": {"ideType": "GEMINI_CLI", "pluginType": "GEMINI"}}` |
| Quota buckets | `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` — body `{"project": "<projectId>"}` (or `{}` if unknown) |
| Project ID discovery | `cloudaicompanionProject` field in `loadCodeAssist` response; fallback `GET https://cloudresourcemanager.googleapis.com/v1/projects` (pick `gen-lang-client*` or label `generative-language`) |
| Token refresh | `POST https://oauth2.googleapis.com/token` — form body `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token` |

**Headers:** `Authorization: Bearer <access_token>`, `Content-Type: application/json`.

**Response parsing (retrieveUserQuota):** buckets carry `modelId`, `remainingFraction` (0..1), `resetTime` (ISO-8601). CodexBar maps percent-left = `remainingFraction * 100`, lowest remaining model wins per family (Pro primary, Flash secondary). OpenUsage derives `used = 100 − remainingFraction·100`, `limit = 100`, and flags `near_limit` at <15%.

**Local auth material:**
- `~/.gemini/oauth_creds.json` — fields: `access_token`, `refresh_token` (optional), `id_token`, `expiry_date` (Unix **millis**), `scope`. Email comes from `id_token` JWT claims; account list in `~/.gemini/google_accounts.json`.
- Auth mode gate: read `~/.gemini/settings.json`; only `oauth-personal` (or unknown) should proceed — `api-key` / `vertex-ai` are not subscription quota.
- **OAuth client ID/secret:** not stored on disk; they are hardcoded in the installed Gemini CLI's `oauth2.js` at `.../node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js` (Homebrew: `/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli/...`). CodexBar regex-extracts `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` from that file (resolution order: `GEMINI_OAUTH_CLIENT_ID`/`_SECRET` env overrides → `GEMINI_OAUTH2_JS_PATH` → installed package → Homebrew Cellar paths). [CodexBar docs/gemini.md]

**Token refresh notes:** honor `expiry_date`; background-refresh via the token endpoint at most once per poll. With a valid refresh token the user should never need to re-auth.

**⚠️ Critical caveat — June 2026 consumer shutdown:** Google stopped serving Gemini CLI OAuth for **individual, AI Pro, and Ultra** accounts on 2026-06-18 (Code Assist Standard/Enterprise and Workspace/education still work). Live shape: `loadCodeAssist` returns HTTP 200 with no `currentTier` and the consumer tier listed under `ineligibleTiers[].reasonCode == "UNSUPPORTED_CLIENT"`; the follow-up `retrieveUserQuota` fails with HTTP 403 `SUBSCRIPTION_REQUIRED`. CodexBar maps these sentinels to a "switch to Antigravity" handoff. AIMeter must detect and handle this. [CodexBar docs/gemini.md; developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals]

### 1b. Antigravity (Google's agentic IDE + `agy` CLI) — verdict: **usable endpoints, three paths** ✅ HIGH confidence

Proven by: CodexBar (PR #635 remote OAuth, PR #937 account switching), OpenUsage `plugins/antigravity` (PR #91), and standalone implementations (`aqua5230/usage`, `quotas` crate, `deviffyy/OpenQuota`, `abruption/agy-cli-usage`).

Antigravity exposes **two shared quota pools**, each with a **rolling 5-hour** and a **weekly** window: (1) "Gemini Models" (Pro + Flash share one pool) and (2) "Claude and GPT models" (Claude, GPT-OSS, …). This mirrors Antigravity's own `/usage` TUI (`antigravity.google/docs/cli/commands/usage/`).

**Path 1 — local language server (richest; app or IDE must be running):**
1. Discover process: `ps -ax -o pid=,command=` — look for `language_server` with `--app_data_dir antigravity` (app) / `antigravity-ide` (IDE extension) / `antigravity-cli`|`agy` (CLI). Extract `--csrf_token <token>`, `--extension_server_port <port>`, `--extension_server_csrf_token <token>` flags.
2. Discover port: `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>`; probe all listening ports.
3. Connect-RPC over **local self-signed HTTPS** (allow insecure TLS **only** for 127.0.0.1):
   - Port probe: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUnleashData` with headers `X-Codeium-Csrf-Token: <token>`, `Connect-Protocol-Version: 1`.
   - Quota (preferred): `.../RetrieveUserQuotaSummary` → `response.groups[].displayName`, `groups[].buckets[].bucketId/displayName/remaining.remainingFraction/description`.
   - Fallbacks: `.../GetUserStatus` (also yields `accountEmail`, `planName`, and legacy `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.remainingFraction/resetTime`), then `.../GetCommandModelConfigs`.
   - Body (summary shape): `{"ideName":"antigravity","extensionName":"antigravity","locale":"en","ideVersion":"unknown"}`.
   - App/IDE servers **require** the CSRF header; the **agy CLI server does not**. IDE local server returns 404 for `RetrieveUserQuotaSummary` (only session/model data, no weekly window).
   - Antigravity is Codeium/Windsurf-derived; protocol is Connect-RPC v1, quota is fraction-based (not credits), no API key in request metadata. [openusage antigravity doc + crossusage fork notes]

**Path 2 — `agy` CLI's embedded local HTTPS server:** the CLI exposes its quota server **only while the interactive process is alive** — launch `agy` under a PTY (never scrape the TUI), wait for endpoint readiness (a fresh `agy` needs a few seconds for keyring auth; it can bind the port before the quota service initializes), then hit the same `RetrieveUserQuotaSummary` / `GetUserStatus` / `GetCommandModelConfigs` endpoints without a CSRF token. `agy` installs via `brew install --cask antigravity-cli` (binary at `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy`; override with `ANTIGRAVITY_CLI_PATH`). CodexBar keeps a bounded warm session (stop on idle, relaunch on repeated failures, never kill a user-launched `agy`). [CodexBar docs/antigravity.md]

**Path 3 — remote OAuth (works with app/CLI closed):** read Antigravity's stored OAuth credential, refresh if stale, then call the Cloud Code API as the Antigravity client:
- Quota: `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` — body `{}`. (`https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` also exists; CodexBar additionally uses `:loadCodeAssist`, `:onboardUser`, `:fetchAvailableModels`, `:retrieveUserQuota` as fallbacks, noting OAuth payloads can be less complete and may only prove model availability.)
- **Required User-Agent** or Cloud Code returns 403 `PERMISSION_DENIED`: `antigravity/<version> <OS>/<arch>` (e.g. `antigravity/1.11.3 Darwin/arm64`).
- Response: `groups[]` (direct, or under `response`/`summary` wrappers) → `displayName`, `buckets[]` → `bucketId`/`displayName` ("5h"/"session" vs "week"), `remaining.remainingFraction`, `resetTime` (ISO-8601), `disabled`.

**Auth material for the remote path (exact, from a working implementation):**
- macOS Keychain: `security find-generic-password -a antigravity -s gemini -w` → JSON, possibly prefixed `go-keyring-base64:` (base64-decode then parse). Shape: `{"token": {"access_token": "...", "expiry": "<RFC3339>", "refresh_token": "..."}}`. (Windows equivalent: Credential Manager target `gemini:antigravity`.)
- Legacy token file (older CLI versions, read-only): `~/.gemini/antigravity-cli/antigravity-oauth-token` (same JSON shape).
- Refresh: `POST https://oauth2.googleapis.com/token` with Antigravity's installed-app public client constants (RFC 8252 public client — secret is intentionally public):
  - `client_id: redacted-google-client-id`
  - `client_secret: redacted-google-client-secret`
  - `grant_type=refresh_token`, `refresh_token=<token>` (if Google rotates these, only quota display breaks — fail soft).
- CodexBar instead performs its **own** OAuth login using Antigravity's client (ID/secret discovered from `Antigravity.app`, overridable via `ANTIGRAVITY_OAUTH_CLIENT_ID`/`_SECRET`) and caches credentials to `~/.codexbar/antigravity/oauth_creds.json` for multi-account switching. [CodexBar PRs #635/#937]
- **Never write back** to Antigravity's keychain item or token file — that is the CLI's home.
- ⚠️ The **Antigravity IDE's own** credentials are Electron `safeStorage`-encrypted (hardware-bound key) and are **not** readable by a third party (SIP/code-signing blocks Frida-style extraction). Use the local LS (no auth needed beyond CSRF) or the `agy` keychain credential instead. [ericxliu.me reverse-engineering write-up]

**Local token history (optional, for spend/token charts):** SQLite conversation DBs at `~/.gemini/antigravity-cli/conversations/*.db`, `~/.gemini/antigravity/*.db`, `~/.gemini/antigravity/conversations/*.db` (`GEMINI_CLI_HOME` replaces `~/.gemini`); fallback JSONL at `~/.config/tokscale/antigravity-cache/sessions/*.jsonl` (`TOKSCALE_CONFIG_DIR` replaces). SQLite `gen_metadata` table, protobuf usage fields 1+2 = input, 5 = cache read, 9 = text output, 10 = thinking output. See tokscale's pinned parser (junhoyeo/tokscale `crates/tokscale-core/src/sessions/antigravity_cli.rs`). [CodexBar docs/antigravity.md]

### 1c. Rate-limit info Gemini CLI itself surfaces — **CLI output only, not a stable data source**

Gemini CLI does print quota: `/stats` (and `/stats session`, `/stats model`) show pooled quota percentages and reset times (PRs #13843, #19612; issue #25598 documents that daily used/left % moved to `/stats model`), plus an exit summary. But there is **no headless/JSON mode** for this and CodexBar explicitly keeps only an unused legacy `/stats` text parser (`GeminiStatusProbe.parse`). Verdict for AIMeter: **do not scrape CLI output**; use the OAuth endpoints in 1a (the same data, from the same backend). Model-response metadata alone does not carry remaining-quota percentages. MEDIUM-HIGH confidence (well documented but secondary to 1a).

---

## TOPIC 2 — OpenCode (sst/opencode → **anomalyco/opencode**)

**Org note:** the repo was transferred from `sst/opencode` to **`anomalyco/opencode`** (PR #6920, Jan 2026; `sst/opencode` URLs still redirect). Docs site: opencode.ai; Homebrew tap `anomalyco/tap/opencode`.

### 2a. Local credential storage — verdict: **local file, plain JSON** ✅ HIGH confidence

- Path (macOS/Linux): `~/.local/share/opencode/auth.json` (or `$XDG_DATA_HOME/opencode/auth.json` if set; Windows: `%USERPROFILE%\.local\share\opencode\auth.json` — XDG-style even on Windows). Defined in `packages/opencode/src/global` (`Global.Path.data`) and shown by `opencode auth list`. [opencode.ai/docs/providers/; docs/cli/auth; source `cli/cmd/auth.ts`]
- Structure: map of provider ID → credential. Two types: **`api`** (`{"type":"api","key":"sk-..."}`) and **`oauth`** (access/refresh tokens + expiry, written by browser-OAuth flows). Providers commonly present: `opencode` (Zen) and `opencode-go` (Go plan) API keys, `openai` (Codex OAuth), `github-copilot` (OAuth), plus API keys for Anthropic/OpenAI/etc. via `/connect`.
- Note: built-in Anthropic (Claude Pro/Max) auth was **removed** in OpenCode 1.3.x (PR #18186); community plugins (`opencode-anthropic-oauth` etc.) restore it and write back into `auth.json` (or read Claude Code's Keychain item `~/.claude/.credentials.json` directly). So Anthropic OAuth presence in `auth.json` depends on the user's plugin setup — do not assume it.
- macOS may also hold related data in `~/.local/share/opencode/opencode.db` (SQLite: sessions, per-message token counts and costs; CodexBar uses `opencode-go` assistant rows for local cost history).

### 2b. Usage/quota API — verdict: **yes for OpenCode's own subscription; no for upstream providers** ✅ HIGH confidence

- **OpenCode Go / Zen subscription quota (official, API-key-authenticated):**
  `GET https://opencode.ai/zen/go/v1/usage` — header `Authorization: Bearer <API_KEY>` where the key is the **regular OpenCode/Zen API key** (same one in `auth.json` under `opencode`/`opencode-go`, or env `OPENCODE_API_KEY`/`ZEN_API_KEY`).
  Response: `{"usage": {"rollingUsage": {"usagePercent": <0..100 number, 1 = 1%>, "resetInSec": <int>}, "weeklyUsage": {...}, "monthlyUsage": {...}}}`. Account-wide, matches the dashboard. Added in PR #16513 (closes issue #16017); used in production by CodexBar (`docs/opencode.md`) and openusage (PR #1097). Reset = `now + resetInSec`.
- **Model list / auth probe:** `GET https://opencode.ai/zen/v1/models` (Bearer key). No spend/quota here.
- **Legacy web path (browser cookie, opt-in):** `POST https://opencode.ai/_server` with server-function IDs — `workspaces` (`def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f`) and `subscription.get` (`7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4`) — authenticated by an `opencode.ai` browser-session cookie; responses are `text/javascript` serialized objects (parse by regex). Fragile; prefer the Go usage API. [CodexBar docs/opencode.md; openusage opencode doc]
- **Upstream provider quotas (Claude/OpenAI/Gemini via OpenCode):** OpenCode merely proxies provider tokens; there is **no** OpenCode API for upstream subscription quota. To show Claude/Codex/Gemini quota for an OpenCode user, AIMeter must reuse the underlying provider credential from `auth.json` and call the upstream provider's endpoint (e.g. CodexBar's opt-in **"External Codex OAuth sources"** reuses the `openai` OAuth entry from OpenCode's `auth.json` for the Codex usage endpoint; native Codex creds take precedence; `CODEX_HOME` set disables the fallback; API-key entries ignored). [CodexBar docs/opencode.md + docs/codex.md]

### 2c. CodexBar / openusage "opencode" plugins — what they do

- **CodexBar `docs/opencode.md` provider:** (1) `GET https://opencode.ai/zen/go/v1/usage` with `OPENCODE_API_KEY`/`providers[].apiKey`; (2) browser-cookie web fallback (Chrome→Dia import, Keychain-cached under `com.steipete.codexbar.cache` account `cookie.opencode`, workspace ID override `CODEXBAR_OPENCODE_WORKSPACE_ID`); (3) local SQLite history from `~/.local/share/opencode/opencode.db` (`opencode-go` rows) for daily cost — labeled `dataConfidence: "estimated"` when no API overlay; (4) external Codex OAuth reuse (above). Reports rolling 5-hour + optional weekly %.
- **openusage `opencode` provider (`docs/providers/opencode.md`):** API-key polling of `/zen/v1/models` for auth + model list only; per-turn spend via its **telemetry plugin** (events tagged by *upstream* provider: anthropic/openai/google); optional console enrichment via `server.queryBilling` with imported browser cookie (balances stored as cents×1e6; divide by 1e8 for USD).
- **TokenBar:** OpenCode appears only as a local-log consumer (tokscale-core parses OpenCode session data); no remote OpenCode quota source. [TokenBar repo]

---

## Cross-cutting: App-Store-sandboxed build — what breaks

Every mechanism above is used by apps that deliberately avoid the Mac App Store (CodexBar via Homebrew/Sparkle; TokenBar via Homebrew cask, ad-hoc signed). In an **App-Store-sandboxed** build, expect breakage of:

1. **Arbitrary process spawning/inspection** — `ps`, `lsof`, `security find-generic-password`, launching `agy` under a PTY, and reading another app's binary to regex-extract OAuth secrets. All forbidden/impossible in sandbox (no `com.apple.security.temporary-exception` for these in MAS).
2. **Reading other apps' home files** — `~/.gemini/*`, `~/.local/share/opencode/*`, `~/.config/tokscale/*`: sandbox containers block reads outside your container unless user-granted via powerbox (not available for arbitrary dotfiles) or a non-sandboxed distribution.
3. **Keychain ACLs** — reading Antigravity's `gemini/antigravity` generic-password item created by a different signing identity triggers prompt/denial; MAS hardened runtime + keychain ACLs make this unreliable. CodexBar's answer is to run its own OAuth login into its own keychain/file.
4. **Self-signed local TLS** — connecting to `https://127.0.0.1:<port>` with insecure-TLS allowance needs ATS exceptions; fine in non-MAS builds, restricted under MAS entitlement review.
5. **Network to private endpoints** (`cloudcode-pa`, `daily-cloudcode-pa`, `opencode.ai`) — fine anywhere, but these are *undocumented* endpoints that Google/Anomaly can change without notice; the Antigravity UA check (`antigravity/x.y.z <os>/<arch>`) and the hardcoded public client secret are reverse-engineering artifacts that may break (e.g. on Gemini CLI's June 2026 consumer shutdown they already did).

**Recommended distribution: notarized/Homebrew/Direct (Developer ID), not MAS.**

---

## Recommended AIMeter implementation

**Topic 1 (Gemini/Antigravity)** — source order:
1. **Antigravity local LS** if Antigravity.app is running (ps+lsof → `RetrieveUserQuotaSummary` → `GetUserStatus`): richest (both pools, weekly+5h, plan name).
2. **`agy` CLI PTY session** when app closed (same endpoints, no CSRF; warm-session lifecycle like CodexBar).
3. **Remote OAuth** using keychain item `gemini`/`antigravity` (or legacy `~/.gemini/antigravity-cli/antigravity-oauth-token`): `POST daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` `{}` with UA `antigravity/<ver> <os>/<arch>`; refresh via `oauth2.googleapis.com/token` with the public client constants. Fall back to `cloudcode-pa...:loadCodeAssist`/`:retrieveUserQuota` for Gemini-CLI-style accounts.
4. **Gemini CLI provider** (Workspace/education/Code Assist Standard accounts only post-June-2026): `~/.gemini/oauth_creds.json` → `:loadCodeAssist` (tier + `cloudaicompanionProject`) → `:retrieveUserQuota`; detect `UNSUPPORTED_CLIENT`/403 `SUBSCRIPTION_REQUIRED` and show an "use Antigravity" handoff instead of an error.
Design notes: parse all three nesting shapes of `groups`; keep worst-fraction-per-pool when only per-model legacy data exists; never write Antigravity credentials back; cache refreshed tokens in-memory only; treat every field as changeable (versions in flags, `Try-After`/429 backoff).

**Topic 2 (OpenCode)** — source order:
1. Read `~/.local/share/opencode/auth.json`; if an `opencode`/`opencode-go` API key exists → `GET https://opencode.ai/zen/go/v1/usage` (Bearer) → rolling/weekly/monthly % + resets.
2. If absent but the binary/config exists, show local-only stats from `~/.local/share/opencode/opencode.db` marked "estimated" (never presented as account quota).
3. Optionally, if `auth.json` holds an `openai` OAuth entry, offer an explicit opt-in to reuse it for Codex quota through the upstream provider's endpoint — clearly labeled as upstream-account data, read-only, stale-credentials fail closed.
4. Avoid the `_server`/cookie path in v1 (fragile, browser-dependent).

---

## Sources

**Kept:**
- CodexBar `docs/gemini.md` — exact Gemini OAuth endpoints, creds file, refresh flow, June-2026 shutdown handling (steipete/CodexBar, cloned repo read).
- CodexBar `docs/antigravity.md` — LS/CLI/OAuth source order, Connect-RPC endpoints, CSRF rules, parsing shapes, local SQLite history (cloned repo read).
- CodexBar `docs/opencode.md` — Go usage API, `_server` function IDs, external Codex OAuth reuse, local DB (cloned repo read).
- CodexBar PR #635 / #937 / issue #936 — OAuth remote fetcher + multi-account storage design.
- openusage.sh `docs/providers/gemini-cli/` — Cloud Code RPCs, file list, near_limit threshold.
- openusage `docs/providers/antigravity.md` (robinebers/openusage) — two-pool model, keychain fallback, RetrieveUserQuotaSummary primacy.
- openusage.sh `docs/providers/opencode/` — API-key detection, models probe, telemetry plugin, console RPC.
- aqua5230/usage `loaders/agy_quota_probe.py` (read in full) — exact keychain service/account (`gemini`/`antigravity`), legacy token path, `daily-cloudcode-pa` URL, UA requirement, public client ID/secret, response shapes.
- google-gemini/gemini-cli PRs #13843/#19612, issue #25598 — `/stats` quota display (confirms 1c is CLI-only).
- anomalyco/opencode PR #6920, PR #16513, issues #16017/#43983 — org transfer, Go usage endpoint, no history endpoint.
- opencode.ai/docs/providers + docs/cli/auth — `auth.json` path and api/oauth credential types.
- abuhanna/winusage README + commits #91/#189 — fork confirming openusage plugin design (antigravity LS + gemini OAuth client discovery).
- antigravity.google/docs/cli (usage command, troubleshooting/keyring) — official confirmation of `/usage` and keyring storage.
- ericxliu.me Antigravity reverse-engineering post — IDE safeStorage not readable.
- Nanako0129/TokenBar README — scope check (local logs only for these providers).

**Dropped:**
- openusage.sh `/docs/providers/antigravity/` — 404 on the site; used the GitHub source instead.
- cc-switch issue #6433, DeepWiki, Mintlify mirror, raggingstar2063/shuv1337/antoinedc plugins — secondary/duplicative; kept only where they established the Anthropic-auth removal fact.
- CodexBar fork/noise docs (issue-2037*, UPSTREAM_STRATEGY, etc.) — irrelevant to these providers.

## Gaps / unknowns
- **No official documentation exists** for any `cloudcode-pa` / `daily-cloudcode-pa` `v1internal` endpoint; shapes verified only by multiple independent implementations. Google can change them silently.
- Whether `retrieveUserQuotaSummary` on `cloudcode-pa` (vs `daily-cloudcode-pa`) is fully equivalent for agy OAuth tokens was not independently verified (CodexBar says current observed OAuth responses there are model-bucket shaped; the `daily-` host with the antigravity UA is what the working `usage` implementation uses for the two-pool summary).
- Exact JSON schema of OpenCode `auth.json` oauth entries (field names for access/refresh/expiry) was not verified from source — only that type `oauth` exists. Next step: read `packages/opencode/src/auth` index module in anomalyco/opencode, or a redacted real `auth.json`.
- Whether Antigravity app (not CLI) also writes a readable keychain item under the same `gemini`/`antigravity` names when the app (vs `agy`) performs sign-in — openusage doc implies the same keychain item; not independently confirmed.
- Gemini CLI OAuth shutdown may evolve (education/Workspace paths); re-verify sentinel strings at implementation time.

---

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "research.md contains concrete file paths (~/.gemini/oauth_creds.json, ~/.gemini/antigravity-cli/antigravity-oauth-token, ~/.local/share/opencode/auth.json, ~/.local/share/opencode/opencode.db), exact endpoints (cloudcode-pa/daily-cloudcode-pa v1internal:*, opencode.ai/zen/go/v1/usage), keychain service/account names, request shapes, token refresh flows, confidence ratings with proving apps, and App-Store-sandbox breakage flags"
    }
  ],
  "changedFiles": [
    "/Users/ni3/.pi/agent/sessions/--Users-ni3-Documents-Personal--/subagent-artifacts/outputs/1916995b-c30a-46e4-8014-4309f3bb724c/research.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "web_search + fetch_content (CodexBar/openusage/opencode repos and docs, 8+ queries)",
      "result": "passed",
      "summary": "Retrieved and read CodexBar docs/antigravity.md, docs/gemini.md, docs/opencode.md, openusage provider docs, agy_quota_probe.py source, and OpenCode auth/usage docs"
    },
    {
      "command": "write research.md to configured output path",
      "result": "passed",
      "summary": "Full structured report written to the authoritative output path"
    }
  ],
  "validationOutput": [
    "All key facts cross-verified across at least two independent implementations (CodexBar + openusage + aqua5230/usage) where possible; unknowns explicitly flagged in Gaps section"
  ],
  "residualRisks": [
    "All Cloud Code v1internal endpoints are undocumented and may change without notice",
    "auth.json oauth-entry exact field names not verified from OpenCode source",
    "Keychain item name for app (vs agy CLI) sign-in not independently confirmed"
  ],
  "noStagedFiles": true,
  "diffSummary": "Added single research deliverable markdown file; no code changes",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "agy_quota_probe.py is AGPL-licensed — facts extracted for the brief only; AIMeter must not copy its code. Gemini CLI OAuth for consumer (individual/Pro/Ultra) accounts is dead since 2026-06-18; Antigravity path is mandatory for those tiers."
}
```