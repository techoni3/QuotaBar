import Foundation
import Testing
@testable import AIMeterCore

struct AntigravityProviderTests {
    // MARK: - Summary parsing

    @Test func summaryFixtureMapsTwoPoolsToWindows() throws {
        let summary = try JSONDecoder.flexibleISO8601.decode(AntigravityQuotaSummary.self,
                                                             from: Fixtures.load("antigravity-quota"))
        let snapshot = AntigravityProvider.snapshot(from: summary, planName: summary.planName, fetchedAt: Date())

        #expect(snapshot.planName == "Antigravity Pro")
        #expect(snapshot.windows.count == 3) // disabled Claude weekly bucket skipped

        let geminiSession = snapshot.windows.first { $0.label == "Gemini models" && $0.kind == .session5h }
        #expect(geminiSession?.usedPercent == 73) // 1 − 0.27
        #expect(geminiSession?.resetsAt == ISO8601Dates.parse("2030-01-01T14:00:00.000Z"))

        let geminiWeek = snapshot.windows.first { $0.label == "Gemini models" && $0.kind == .week7d }
        #expect(geminiWeek?.usedPercent == 9) // 1 − 0.91

        let claudeSession = snapshot.windows.first { $0.label == "Claude and GPT models" && $0.kind == .session5h }
        #expect(claudeSession?.usedPercent == 95) // 1 − 0.05
        #expect(snapshot.windows.first { $0.label == "Claude and GPT models" && $0.kind == .week7d } == nil)
    }

    @Test func nestedWrappersResponseAndSummaryParse() throws {
        let root = #"{"groups": []}"#
        let wrapped = #"{"response": {"groups": []}}"#
        let summarized = #"{"summary": {"groups": []}}"#
        for payload in [root, wrapped, summarized] {
            let summary = try JSONDecoder.flexibleISO8601.decode(AntigravityQuotaSummary.self,
                                                                from: Data(payload.utf8))
            #expect(summary.groups != nil)
        }
    }

    // MARK: - Path 1: local language server

    @Test func localLanguageServerQuotaUsesPortAndCsrf() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.absoluteString == "https://127.0.0.1:57755/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
            #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "csrf-abc")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = request.aimeterBodyText ?? ""
            #expect(body.contains("\"ideName\":\"antigravity\""))
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        let probe = StubLSProbe(AntigravityLanguageServer(port: 57755, csrfToken: "csrf-abc"))
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: probe,
                                           keychainReader: StubKeychain(nil),
                                           refresher: StubRefresh(RefreshedToken(accessToken: "x", refreshToken: nil)))

        let snapshot = try await provider.fetchUsage()

        #expect(probe.calls == 1)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.planName == "Antigravity Pro")
    }

    @Test func agyCliServerHasNoCsrfHeader() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == nil)
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        let probe = StubLSProbe(AntigravityLanguageServer(port: 59000, csrfToken: nil))
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: probe,
                                           keychainReader: StubKeychain(nil),
                                           refresher: StubRefresh(RefreshedToken(accessToken: "x", refreshToken: nil)))
        _ = try await provider.fetchUsage()
    }

    // MARK: - Path 3: remote OAuth

    @Test func remoteOAuthPostsWithUAAndBearer() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stored-access")
            let body = request.aimeterBodyText ?? ""
            #expect(body == "{}")
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        let creds = AntigravityOAuthCredentials(accessToken: "stored-access",
                                                expiry: Date().addingTimeInterval(3600),
                                                refreshToken: nil)
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(creds),
                                           refresher: StubRefresh(RefreshedToken(accessToken: "r", refreshToken: nil)))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.windows.count == 3)
    }

    @Test func staleTokenTriggersOAuthRefreshWithPublicClient() async throws {
        let stub = StubSession()
        stub.respond { request in
            if request.url?.absoluteString == "https://oauth2.googleapis.com/token" {
                #expect(request.httpMethod == "POST")
                let body = request.aimeterBodyText ?? ""
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("client_id=redacted-google-client-id"))
                #expect(body.contains("client_secret=redacted-google-client-secret"))
                #expect(body.contains("refresh_token=stale-refresh"))
                return .ok(Data(#"{"access_token": "fresh-token", "expires_in": 3600}"#.utf8))
            }
            if request.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
                return .ok(try Fixtures.load("antigravity-quota"))
            }
            return .init(status: 599, data: Data(), headers: [:])
        }
        let creds = AntigravityOAuthCredentials(accessToken: "stale-token",
                                                expiry: Date().addingTimeInterval(-60),
                                                refreshToken: "stale-refresh")
        let refresher = StubRefresh(RefreshedToken(accessToken: "fresh-token", refreshToken: nil))
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(creds),
                                           refresher: refresher)

        _ = try await provider.fetchUsage()

        #expect(refresher.calls == ["stale-refresh"])
    }

    @Test func noKeychainItemIsUnauthorized() async {
        let stub = StubSession()
        stub.respond { _ in .init(status: 599, data: Data(), headers: [:]) }
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           refresher: StubRefresh(RefreshedToken(accessToken: "x", refreshToken: nil)))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            #expect(error.isRetryable == false)
            if case .unauthorized = error {} else {
                Issue.record("expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    // MARK: - Credential parse

    @Test func keychainParseDecodesPlainJSON() throws {
        let data = Data(#"{"token": {"access_token": "at-1", "expiry": "2030-01-01T00:00:00Z", "refresh_token": "rt-1"}}"#.utf8)
        let creds = try #require(KeychainAntigravityKeychainReader.parse(data))
        #expect(creds.accessToken == "at-1")
        #expect(creds.refreshToken == "rt-1")
        #expect(creds.expiry == ISO8601Dates.parse("2030-01-01T00:00:00Z"))
    }

    @Test func keychainParseDecodesGoKeyringBase64Prefix() throws {
        let inner = Data(#"{"token": {"access_token": "b64-at"}}"#.utf8)
        let wrapped = "go-keyring-base64:" + inner.base64EncodedString()
        let creds = try #require(KeychainAntigravityKeychainReader.parse(Data(wrapped.utf8)))
        #expect(creds.accessToken == "b64-at")
    }
}

// MARK: - Stubs

private final class StubLSProbe: AntigravityLanguageServerProbe, @unchecked Sendable {
    let result: AntigravityLanguageServer?
    nonisolated(unsafe) private(set) var calls = 0

    init(_ result: AntigravityLanguageServer?) { self.result = result }

    func locateLanguageServer() async -> AntigravityLanguageServer? {
        calls += 1
        return result
    }
}

private struct StubKeychain: AntigravityKeychainReader {
    let creds: AntigravityOAuthCredentials?
    init(_ creds: AntigravityOAuthCredentials?) { self.creds = creds }
    func readCredentials() async throws -> AntigravityOAuthCredentials? { creds }
}

private final class StubRefresh: AntigravityOAuthRefresher, @unchecked Sendable {
    nonisolated(unsafe) private(set) var calls: [String] = []
    let result: RefreshedToken

    init(_ result: RefreshedToken) { self.result = result }

    func refresh(refreshToken: String) async throws -> RefreshedToken {
        calls.append(refreshToken)
        return result
    }
}
struct PiAntigravityWiringTests {
    private static func piFixtureURL() -> URL {
        Bundle.module.url(forResource: "pi-auth", withExtension: "json", subdirectory: "Fixtures")!
    }

    @Test func piOAuthConnectsRemotePathWithoutKeychain() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29-pi-access")
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        // No local probe, no keychain — Pi's OAuth entry drives the remote path.
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: FilePiAuthSource(explicitPath: Self.piFixtureURL()),
                                           refresher: StubRefresh(RefreshedToken(accessToken: "x", refreshToken: nil)))

        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.count == 3)
    }

    @Test func stalePiTokenTriggersRefreshWithPiRefreshToken() async throws {
        let stub = StubSession()
        stub.respond { request in
            if request.url?.absoluteString == "https://oauth2.googleapis.com/token" {
                return .ok(Data(#"{"access_token": "pi-fresh", "expires_in": 3600}"#.utf8))
            }
            if request.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pi-fresh")
                return .ok(try Fixtures.load("antigravity-quota"))
            }
            return .init(status: 599, data: Data(), headers: [:])
        }
        // Synthesize a stale pi antigravity entry (expiry in the past).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-pi-antigrav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("auth.json")
        let pastMillis = Int(Date().timeIntervalSince1970 * 1000) - 600_000
        try Data("""
        {"antigravity": {"type": "oauth", "access": "stale-pi", "refresh": "pi-refresh-1", "expires": \(pastMillis)}}
        """.utf8).write(to: stale)

        let refresher = StubRefresh(RefreshedToken(accessToken: "pi-fresh", refreshToken: nil))
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: FilePiAuthSource(explicitPath: stale),
                                           refresher: refresher)
        _ = try await provider.fetchUsage()
        #expect(refresher.calls == ["pi-refresh-1"])
    }

    @Test func keychainFallsBackWhenPiHasNoCredential() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer keychain-token")
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        let emptyPi = FilePiAuthSource(
            explicitPath: URL(fileURLWithPath: "/nonexistent/pi/agent/auth.json"),
            legacyExplicitPath: URL(fileURLWithPath: "/nonexistent/pi/auth.json"))
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(AntigravityOAuthCredentials(
                                               accessToken: "keychain-token", expiry: Date().addingTimeInterval(3600), refreshToken: nil)),
                                           piAuth: emptyPi,
                                           refresher: StubRefresh(RefreshedToken(accessToken: "x", refreshToken: nil)))
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.count == 3)
    }
}

struct AntigravityWindowOrderTests {
    @Test func mapsBothPools5hThenWeekly() throws {
        // Two pools × (5h + weekly) all enabled → 4 windows, 5h before weekly
        // per pool, pool order preserved (Gemini models then Claude and GPT).
        let payload = #"""
        {"groups": [
          {"displayName": "Gemini models", "buckets": [
            {"bucketId": "g5h", "displayName": "5h", "remaining": {"remainingFraction": 0.3}, "disabled": false},
            {"bucketId": "gwk", "displayName": "Weekly", "remaining": {"remainingFraction": 0.9}, "disabled": false}]},
          {"displayName": "Claude and GPT models", "buckets": [
            {"bucketId": "c5h", "displayName": "5h", "remaining": {"remainingFraction": 0.1}, "disabled": false},
            {"bucketId": "cwk", "displayName": "Weekly", "remaining": {"remainingFraction": 0.7}, "disabled": false}]}
        ]}
        """#
        let summary = try JSONDecoder.flexibleISO8601.decode(AntigravityQuotaSummary.self, from: Data(payload.utf8))
        let snapshot = AntigravityProvider.snapshot(from: summary, planName: nil, fetchedAt: Date())

        #expect(snapshot.windows.count == 4)
        #expect(snapshot.windows.map(\.kind) == [.session5h, .week7d, .session5h, .week7d])
        #expect(snapshot.windows.map(\.label) == ["Gemini models", "Gemini models", "Claude and GPT models", "Claude and GPT models"])
    }
}

struct AntigravityLegacyShapeTests {
    @Test func decodesNestedRemainingFallback() throws {
        // Older doc shape: remainingFraction nested under `remaining`.
        let payload = #"""
        {"groups": [{"displayName": "Gemini models", "buckets": [
          {"bucketId": "g5h", "displayName": "5h", "remaining": {"remainingFraction": 0.25}, "resetTime": "2030-01-01T00:00:00Z"}]}]}
        """#
        let summary = try JSONDecoder.flexibleISO8601.decode(AntigravityQuotaSummary.self, from: Data(payload.utf8))
        let snapshot = AntigravityProvider.snapshot(from: summary, planName: nil, fetchedAt: Date())
        #expect(snapshot.windows.map(\.usedPercent) == [75]) // 1 − 0.25
    }
}

struct AntigravityTimeoutTests {
    @Test func withTimeoutAbortsStalledStep() async {
        let start = Date()
        do {
            _ = try await AntigravityProvider.withTimeout(0.3) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            Issue.record("expected timeout")
        } catch let error as ProviderError {
            #expect(Date().timeIntervalSince(start) < 3) // bounded, not 5s
            #expect(error.isRetryable)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func withTimeoutCompletesFastOps() async throws {
        let value = try await AntigravityProvider.withTimeout(2) { 42 }
        #expect(value == 42)
    }

    @Test func boundedLocalLsFallsBackToRemoteOnFailure() async throws {
        let stub = StubSession()
        stub.respond { request in
            // Pi remote path is reachable; local LS (probe stub) returns a
            // failing/hanging 127.0.0.1 target → 599 via the stub → fallback.
            if request.url?.absoluteString.contains("127.0.0.1") == true {
                return .init(status: 599, data: Data(), headers: [:])
            }
            #expect(request.url?.absoluteString.contains("daily-cloudcode-pa") == true)
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(AntigravityLanguageServer(port: 1, csrfToken: nil)),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: FilePiAuthSource(explicitPath: Self.piFixtureURL()),
                                           refresher: StubRefresh(RefreshedToken(accessToken: "x", refreshToken: nil)))
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.count == 3)
    }

    private static func piFixtureURL() -> URL {
        Bundle.module.url(forResource: "pi-auth", withExtension: "json", subdirectory: "Fixtures")!
    }
}
