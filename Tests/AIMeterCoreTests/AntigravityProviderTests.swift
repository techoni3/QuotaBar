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