import Foundation
import Testing
@testable import AIMeterCore

struct PiAuthTests {
    private static func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "pi-auth", withExtension: "json", subdirectory: "Fixtures"))
    }

    @Test func decodesAgentFixtureSchema() throws {
        let file = try JSONDecoder().decode(PiAuthFile.self, from: Fixtures.load("pi-auth"))
        #expect(file.entries["opencode-go"]?.key == "sk-pi-opencode-go")
        #expect(file.entries["ollama"]?.key == "sk-pi-ollama")
        #expect(file.entries["antigravity"]?.access == "ya29-pi-access")
        #expect(file.entries["antigravity"]?.refresh == "1//0-pi-refresh")
        #expect(file.entries["antigravity"]?.expires == 6_942_000_000_000)
        // Non-object root values (the _comment) are skipped, not fatal.
        #expect(file.entries.count == 4)
    }

    @Test func fileSourceReturnsApiKeyAndAccessToken() async throws {
        let source = FilePiAuthSource(explicitPath: try Self.fixtureURL())
        #expect(source.apiKey(for: "opencode-go") == "sk-pi-opencode-go")
        #expect(source.apiKey(for: "ollama") == "sk-pi-ollama")
        #expect(source.apiKey(for: "opencode") == "sk-pi-opencode")
        // OAuth entry: no api `key`, but an access token.
        #expect(source.apiKey(for: "antigravity") == nil)
        #expect(source.accessToken(for: "antigravity") == "ya29-pi-access")
        #expect(source.refreshToken(for: "antigravity") == "1//0-pi-refresh")
        // expires is Unix milliseconds → Date.
        #expect(source.expiryDate(for: "antigravity") == Date(timeIntervalSince1970: 6_942_000_000))
        // Unknown provider → nil.
        #expect(source.apiKey(for: "nope") == nil)
    }

    @Test func piAntigravitySourceBuildsCredentialsFromOAuthEntry() throws {
        let source = PiAntigravityTokenSource(auth: FilePiAuthSource(explicitPath: try Self.fixtureURL()))
        let creds = try #require(source.credentials)
        #expect(creds.accessToken == "ya29-pi-access")
        #expect(creds.refreshToken == "1//0-pi-refresh")
        #expect(creds.expiry == Date(timeIntervalSince1970: 6_942_000_000))
    }

    @Test func piAntigravitySourceIsNilWithoutCredential() {
        let source = PiAntigravityTokenSource(auth: FilePiAuthSource(
            explicitPath: URL(fileURLWithPath: "/nonexistent/pi/agent/auth.json"),
            legacyExplicitPath: URL(fileURLWithPath: "/nonexistent/pi/auth.json")))
        #expect(source.credentials == nil)
    }

    @Test func missingAgentFileFallsBackToLegacyPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-pi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("auth.json")
        try Data(#"{"ollama": {"type": "api", "key": "sk-legacy-ollama"}}"#.utf8).write(to: legacy)

        // Agent path (explicit) does not exist; legacy does → reader finds it.
        let source = FilePiAuthSource(
            explicitPath: dir.appendingPathComponent("absent-agent-auth.json"),
            legacyExplicitPath: legacy
        )
        #expect(source.apiKey(for: "ollama") == "sk-legacy-ollama")
    }

    @Test func noPiFileIsNilEverywhere() {
        let source = FilePiAuthSource(
            explicitPath: URL(fileURLWithPath: "/nonexistent/pi/agent/auth.json"),
            legacyExplicitPath: URL(fileURLWithPath: "/nonexistent/pi/auth.json")
        )
        #expect(source.apiKey(for: "opencode-go") == nil)
        #expect(source.accessToken(for: "antigravity") == nil)
    }

    @Test func piOpenCodeSourcePrefersGoEntry() async throws {
        let source = PiOpenCodeTokenSource(auth: FilePiAuthSource(explicitPath: try Self.fixtureURL()))
        #expect(try await source.accessToken() == "sk-pi-opencode-go")
    }

    @Test func piOpenCodeSourceThrowsWhenNoKey() async {
        let auth = FilePiAuthSource(
            explicitPath: URL(fileURLWithPath: "/nonexistent/pi/agent/auth.json"),
            legacyExplicitPath: URL(fileURLWithPath: "/nonexistent/pi/auth.json")
        )
        let source = PiOpenCodeTokenSource(auth: auth)
        do {
            _ = try await source.accessToken()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            if case .unauthorized = error {} else {
                Issue.record("expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }
}

/// Fixture URL for the synthetic ~/.pi credential file (bundled in Fixtures/).
private func piFixtureURL() -> URL {
    Bundle.module.url(forResource: "pi-auth", withExtension: "json", subdirectory: "Fixtures")!
}

struct PiCompositeOrderTests {
    @Test func compositeOrderFileThenPiThenVault() async throws {
        let vault = InMemoryCredentialVault()
        try vault.storeToken("vault-key", for: ProviderID("opencode"))
        // File source points at a missing auth.json → Pi's stored key wins over
        // the vault (File freshest > Pi > Vault).
        let source = CompositeOpenCodeTokenSource([
            FileOpenCodeTokenSource(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/opencode/auth.json")),
            PiOpenCodeTokenSource(auth: FilePiAuthSource(explicitPath: piFixtureURL())),
            VaultOpenCodeTokenSource(vault: vault, providerID: ProviderID("opencode")),
        ])
        #expect(try await source.accessToken() == "sk-pi-opencode-go")
    }

    @Test func vaultWinsWhenPiHasNoKey() async throws {
        let vault = InMemoryCredentialVault()
        try vault.storeToken("vault-key", for: ProviderID("opencode"))
        let emptyPi = FilePiAuthSource(
            explicitPath: URL(fileURLWithPath: "/nonexistent/pi/agent/auth.json"),
            legacyExplicitPath: URL(fileURLWithPath: "/nonexistent/pi/auth.json")
        )
        let source = CompositeOpenCodeTokenSource([
            FileOpenCodeTokenSource(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/opencode/auth.json")),
            PiOpenCodeTokenSource(auth: emptyPi),
            VaultOpenCodeTokenSource(vault: vault, providerID: ProviderID("opencode")),
        ])
        #expect(try await source.accessToken() == "vault-key")
    }
}
