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
        #expect(file.entries["antigravity"]?.expires == 1_788_066_531_500)
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
        // Unknown provider → nil.
        #expect(source.apiKey(for: "nope") == nil)
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

struct OllamaCloudTests {
    @Test func cloudKeyShowsConnectedWithoutNetwork() async throws {
        let stub = StubSession()
        stub.respond { _ in .init(status: 599, data: Data(), headers: [:]) } // any network ⇒ failure
        let provider = OllamaProvider(session: stub.session,
                                      cloudAuth: FilePiAuthSource(explicitPath: piFixtureURL()))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.status == .ok)
        #expect(snapshot.planName == "Ollama Cloud — connected")
        #expect(snapshot.windows.first?.label?.contains("Cloud") == true)
        // No localhost probe happened — the pi key short-circuits to cloud.
        #expect(stub.requests().isEmpty)
    }

    @Test func noCloudKeyKeepsLocalBehavior() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/api/ps")
            return .ok(try Fixtures.load("ollama-ps"))
        }
        let provider = OllamaProvider(session: stub.session) // no cloudAuth

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.status == .local)
        #expect(snapshot.planName == "local — no subscription quota")
        #expect(stub.requests().count == 1)
    }
}