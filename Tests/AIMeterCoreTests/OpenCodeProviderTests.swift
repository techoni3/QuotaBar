import Foundation
import Testing
@testable import AIMeterCore

struct OpenCodeProviderTests {
    @Test func parsesUsageFixtureWindows() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("opencode-usage")) }
        let provider = OpenCodeProvider(session: stub.session,
                                        tokenSource: StubOpenCodeTokenSource("sk-test"))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == "OpenCode Go")
        #expect(snapshot.windows.count == 3)
        let session = snapshot.windows.first { $0.kind == .session5h }
        #expect(session?.usedPercent == 13)
        #expect(session?.resetsAt != nil)
        let week = snapshot.windows.first { $0.kind == .week7d }
        #expect(week?.usedPercent == 66)
        let month = snapshot.windows.first { $0.kind == .month }
        #expect(month?.usedPercent == 83)
    }

    @Test func sendsBearerToUsageURL() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("opencode-usage")) }
        let provider = OpenCodeProvider(session: stub.session,
                                        tokenSource: StubOpenCodeTokenSource("sk-secret-1"))

        _ = try await provider.fetchUsage()

        let request = try #require(stub.requests().first)
        #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func authFilePrefersGoEntry() throws {
        let file = try JSONDecoder().decode(OpenCodeAuthFile.self, from: Fixtures.load("opencode-auth"))
        #expect(file.apiKey == "sk-opencode-go-test-123")
    }

    @Test func fileTokenSourceReadsFixtureKey() async throws {
        let url = try #require(Bundle.module.url(forResource: "opencode-auth", withExtension: "json", subdirectory: "Fixtures"))
        let source = FileOpenCodeTokenSource(explicitPath: url)
        #expect(try await source.accessToken() == "sk-opencode-go-test-123")
    }

    @Test func missingAuthFileIsNotInstalled() async {
        let source = FileOpenCodeTokenSource(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/opencode/auth.json"))
        do {
            _ = try await source.accessToken()
            Issue.record("expected notInstalled")
        } catch let error as ProviderError {
            #expect(error == .notInstalled)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func keylessAuthFileIsUnauthorized() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("auth.json")
        try Data(#"{"openai": {"type": "oauth", "access_token": "x"}}"#.utf8).write(to: path)

        let source = FileOpenCodeTokenSource(explicitPath: path)
        do {
            _ = try await source.accessToken()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            if case .unauthorized = error {} else {
                Issue.record("expected unauthorized, got \(error)")
            }
        }
    }

    @Test func compositeFallsBackToVault() async throws {
        let vault = InMemoryCredentialVault()
        try vault.storeToken("vault-key", for: ProviderID("opencode"))
        let source = CompositeOpenCodeTokenSource([
            FileOpenCodeTokenSource(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/auth.json")),
            VaultOpenCodeTokenSource(vault: vault, providerID: ProviderID("opencode")),
        ])
        #expect(try await source.accessToken() == "vault-key")
    }

    @Test func readerHonorsXDGDataHome() {
        let source = FileOpenCodeTokenSource(environment: ["XDG_DATA_HOME": "/tmp/custom-data"])
        #expect(source.path == URL(fileURLWithPath: "/tmp/custom-data/opencode/auth.json"))
    }

    @Test func garbagePayloadBecomesUnavailable() async {
        let stub = StubSession()
        stub.respond { _ in .ok(Data("not json".utf8)) }
        let provider = OpenCodeProvider(session: stub.session, tokenSource: StubOpenCodeTokenSource("t"))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            #expect(error.isRetryable)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }
}

private struct StubOpenCodeTokenSource: OpenCodeTokenSource {
    let token: String
    init(_ token: String) { self.token = token }
    func accessToken() async throws -> String { token }
}
struct OpenCodeWindowOrderTests {
    @Test func mapsAllThreeWindowsInOrder() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("opencode-usage")) }
        let provider = OpenCodeProvider(session: stub.session, tokenSource: StubOpenCodeTokenSource("k"))

        let snapshot = try await provider.fetchUsage()

        // rolling → 5h, weekly → 7d, monthly → month, in that order.
        #expect(snapshot.windows.map(\.kind) == [.session5h, .week7d, .month])
    }
}

struct OpenCodeLegacyShapeTests {
    @Test func decodesLegacyRollingUsageShape() async throws {
        let stub = StubSession()
        stub.respond { _ in
            .ok(Data(#"{"usage": {"rollingUsage": {"usagePercent": 42, "resetInSec": 18000}}}"#.utf8))
        }
        let provider = OpenCodeProvider(session: stub.session, tokenSource: StubOpenCodeTokenSource("k"))
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.kind == .session5h)
        #expect(snapshot.windows.first?.usedPercent == 42)
        #expect(snapshot.windows.first?.resetsAt != nil)
    }
}
