# QuotaBar security guidance

QuotaBar's AIMeter app is a development-stage, non-sandboxed macOS application that reads local
provider credentials and makes authenticated provider requests. It is not an
authentication manager or a substitute for the providers' account-security tools.

## Reporting a vulnerability

Do not post tokens, credential files, account identifiers, private signing keys,
or exploit details in a public issue.

A dedicated security contact and supported-version policy have not yet been
published. If the repository offers GitHub private vulnerability reporting, use
that channel. Otherwise, ask the maintainer for a private reporting channel
without including sensitive details publicly. No response-time guarantee is
currently defined.

## Credential handling

- Pi and native provider credential files must remain read-only.
- Codex OAuth refreshes stay in memory; AIMeter does not write them back to Pi
  or the Codex CLI credential file.
- Explicitly imported credentials use the macOS Keychain.
- Usage snapshots are cached locally. Redact account and usage details before
  sharing logs, screenshots, or fixtures.
- Never commit signing keys or use real access/refresh tokens in tests.

## Installing builds

The currently packaged local build is ad-hoc signed, not Developer ID signed or
notarized. A valid ad-hoc signature and matching checksum do not establish a
trusted publisher. Install only from sources you trust; do not disable Gatekeeper
globally. Public releases should be signed, notarized, and accompanied by accurate
release and update-feed metadata.

Dependencies, including Sparkle and swift-testing, are declared in
[Package.swift](Package.swift); resolved versions are recorded in
[Package.resolved](Package.resolved).
