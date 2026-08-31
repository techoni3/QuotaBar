import Foundation
import Testing
@testable import AIMeterCore

struct CodexProviderTests {
    @Test func parsesFixture() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("codex-usage")) }
        let provider = CodexProvider(session: stub.session,
                                     authReader: FileCodexAuthReader(explicitPath: try authFixturePath()),
                                     tokenRefresher: StubTokenRefresher(result: .failure(ProviderError.unavailable("unused"))))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == "ChatGPT Plus")
        #expect(snapshot.windows.count == 3)

        let session = snapshot.windows.first { $0.kind == .session5h }
        #expect(session?.usedPercent == 6)
        #expect(session?.resetsAt == Date(timeIntervalSince1970: 1_900_003_600))

        let week = snapshot.windows.first { $0.kind == .week7d && $0.label == nil }
        #expect(week?.usedPercent == 24)

        let codeReview = snapshot.windows.first { $0.label == "Code review" }
        #expect(codeReview?.usedPercent == 0)
    }

    @Test func sendsBearerAndAccountHeaders() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("codex-usage")) }
        let provider = CodexProvider(session: stub.session,
                                     authReader: FileCodexAuthReader(explicitPath: try authFixturePath()),
                                     tokenRefresher: StubTokenRefresher(result: .failure(ProviderError.unavailable("unused"))))

        _ = try await provider.fetchUsage()

        let request = try #require(stub.requests().first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func missingAuthFileIsNotInstalled() async {
        let reader = FileCodexAuthReader(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/auth.json"))
        let provider = CodexProvider(session: StubSession().session, authReader: reader,
                                     tokenRefresher: StubTokenRefresher(result: .failure(ProviderError.unavailable("x"))))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected notInstalled")
        } catch let error as ProviderError {
            #expect(error == .notInstalled)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func apiKeyOnlyAuthFileIsUnauthorized() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("auth.json")
        try Data(#"{"OPENAI_API_KEY": "sk-abc", "tokens": null}"#.utf8).write(to: path)

        let provider = CodexProvider(session: StubSession().session,
                                     authReader: FileCodexAuthReader(explicitPath: path),
                                     tokenRefresher: StubTokenRefresher(result: .failure(ProviderError.unavailable("x"))))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            if case .unauthorized = error {} else {
                Issue.record("expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func refreshesInMemoryOn401AndRetries() async throws {
        let authPath = try authFixturePath()
        let stub = StubSession()
        stub.respond { request in
            let token = request.value(forHTTPHeaderField: "Authorization")
            if token == "Bearer test-access-token" {
                return .init(status: 401, data: Data(), headers: [:])
            }
            return .ok(try Fixtures.load("codex-usage"))
        }
        let refresher = StubTokenRefresher(result: .success(RefreshedToken(
            accessToken: "fresh-token", refreshToken: "rotated-token", issuedAt: Date()
        )))
        let provider = CodexProvider(session: stub.session,
                                     authReader: FileCodexAuthReader(explicitPath: authPath),
                                     tokenRefresher: refresher)

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == "ChatGPT Plus")
        #expect(refresher.calls == ["test-refresh-token"])

        // Refreshed token is cached in memory: a second fetch goes straight out
        // with the fresh token and never touches auth.json on disk.
        _ = try await provider.fetchUsage()
        #expect(refresher.calls.count == 1)
        let lastRequest = try #require(stub.requests().last)
        #expect(lastRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }

    @Test func proactiveRefreshWhenStale() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("auth.json")
        // last_refresh 9 days ago → stale (>8 days).
        let staleDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-9 * 86_400))
        let payload = """
        {"OPENAI_API_KEY": null,
         "tokens": {"access_token": "stale-token", "refresh_token": "stale-refresh", "id_token": null, "account_id": "acc-9"},
         "last_refresh": "\(staleDate)"}
        """
        try Data(payload.utf8).write(to: path)

        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("codex-usage")) }
        let refresher = StubTokenRefresher(result: .success(RefreshedToken(
            accessToken: "proactively-refreshed", refreshToken: nil, issuedAt: Date()
        )))
        let provider = CodexProvider(session: stub.session,
                                     authReader: FileCodexAuthReader(explicitPath: path),
                                     tokenRefresher: refresher)

        _ = try await provider.fetchUsage()

        #expect(refresher.calls == ["stale-refresh"])
        let request = try #require(stub.requests().first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer proactively-refreshed")
    }

    @Test func vaultFallbackUsedWhenAuthFileMissing() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer imported-token")
            return .ok(try Fixtures.load("codex-usage"))
        }
        let vault = InMemoryCredentialVault()
        try vault.storeToken("imported-token", for: CodexProvider.providerID)
        let provider = CodexProvider(
            session: stub.session,
            authReader: FileCodexAuthReader(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/auth.json")),
            tokenRefresher: StubTokenRefresher(result: .failure(ProviderError.unavailable("unused"))),
            tokenFallback: VaultCodexTokenFallback(vault: vault, providerID: CodexProvider.providerID)
        )

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == "ChatGPT Plus")
    }

    @Test func vaultFallbackSkipsWhenTokenStoredForAnotherProvider() async throws {
        let stub = StubSession()
        stub.respond { _ in .init(status: 599, data: Data(), headers: [:]) }
        let vault = InMemoryCredentialVault()
        try vault.storeToken("wrong-token", for: ProviderID("not-codex"))
        let provider = CodexProvider(
            session: stub.session,
            authReader: FileCodexAuthReader(explicitPath: URL(fileURLWithPath: "/nonexistent/aimeter-test/auth.json")),
            tokenRefresher: StubTokenRefresher(result: .failure(ProviderError.unavailable("unused"))),
            tokenFallback: VaultCodexTokenFallback(vault: vault, providerID: CodexProvider.providerID)
        )

        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected notInstalled when no fallback token")
        } catch let error as ProviderError {
            #expect(error == .notInstalled)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func readerHonorsCodexHomeEnv() {
        let home = URL(fileURLWithPath: "/tmp/some-codex-home")
        let reader = FileCodexAuthReader(environment: ["CODEX_HOME": home.path])
        #expect(reader.path == home.appendingPathComponent("auth.json"))
    }

    @Test func planNameMapping() {
        #expect(CodexUsageResponse.planName("plus") == "ChatGPT Plus")
        #expect(CodexUsageResponse.planName("pro") == "ChatGPT Pro")
        #expect(CodexUsageResponse.planName("enterprise") == "ChatGPT Enterprise")
        #expect(CodexUsageResponse.planName("weird_tier") == "ChatGPT Weird Tier")
        #expect(CodexUsageResponse.planName(nil) == nil)
    }

    // MARK: - Auth file decoding

    @Test func decodesAuthFixture() throws {
        let file = try JSONDecoder.flexibleISO8601.decode(CodexAuthFile.self, from: Fixtures.load("codex-auth"))
        let tokens = try #require(file.tokens)
        #expect(tokens.accessToken == "test-access-token")
        #expect(tokens.refreshToken == "test-refresh-token")
        #expect(tokens.accountID == "acc-123")
        #expect(file.lastRefresh == ISO8601Dates.parse("2026-01-28T08:05:37Z"))
    }

    @Test func openAIRefresherPostsFormEncodedGrant() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
            #expect(request.httpMethod == "POST")
            let body = request.aimeterBodyText ?? ""
            #expect(body.contains("grant_type=refresh_token"))
            #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
            #expect(body.contains("refresh_token=abc"))
            return .ok(Data(#"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}"#.utf8))
        }
        let refresher = OpenAITokenRefresher(session: stub.session)
        let refreshed = try await refresher.refresh(refreshToken: "abc")
        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "new-refresh")
    }

    private func authFixturePath() throws -> URL {
        let url = try #require(Bundle.module.url(forResource: "codex-auth", withExtension: "json", subdirectory: "Fixtures"))
        return url
    }
}
