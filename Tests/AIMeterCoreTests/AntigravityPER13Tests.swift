import Foundation
import Testing
@testable import AIMeterCore

/// PER-13: Pi token auto-refresh so the Antigravity HUD row reappears.
struct AntigravityPER13Tests {
    // Fixture with 4 windows: Gemini 100% (0.0), Gemini weekly 66% (0.34),
    // Claude 5h 0% (1.0), Claude weekly 34% (0.66) — live shape.
    @Test func expiredPiTokenTriggersRefreshThenFourWindows() async throws {
        let stub = StubSession()
        var tokenCalls = 0
        var quotaCalls = 0
        stub.respond { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://oauth2.googleapis.com/token" {
                tokenCalls += 1
                #expect(request.httpMethod == "POST")
                let body = request.aimeterBodyText ?? ""
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("client_id=test-antigravity-client"))
                #expect(body.contains("client_secret=test-antigravity-secret"))
                #expect(body.contains("refresh_token=pi-refresh-live"))
                return .ok(Data(#"{"access_token": "fresh-live-token", "expires_in": 3600}"#.utf8))
            }
            if url.contains("retrieveUserQuotaSummary") {
                quotaCalls += 1
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-live-token")
                #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/") == true)
                return .ok(try Fixtures.load("antigravity-quota-live-4windows"))
            }
            return .init(status: 599, data: Data(), headers: [:])
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-per13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let piFile = dir.appendingPathComponent("auth.json")
        let pastMillis = Int(Date().timeIntervalSince1970 * 1000) - 600_000 // expired 10m ago
        try Data("""
        {"antigravity": {"type": "oauth", "access": "stale-pi-access", "refresh": "pi-refresh-live", "expires": \(pastMillis)}}
        """.utf8).write(to: piFile)

        let piAuth = FilePiAuthSource(explicitPath: piFile)
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: piAuth,
                                           refresher: GoogleAntigravityOAuthRefresher(session: stub.session, client: testAntigravityOAuthClient))

        let snapshot = try await provider.fetchUsage()

        #expect(tokenCalls == 1, "expired pi token must trigger one oauth2 refresh")
        #expect(quotaCalls >= 1)
        #expect(snapshot.windows.count == 4, "both pools × 2 windows = 4")

        // Verify live percentages: Gemini 100% (remaining 0.0), Claude weekly 34% (0.66), Claude 5h 0% (1.0)
        let gemini5h = snapshot.windows.first { $0.label == "Gemini models" && $0.kind == .session5h }
        #expect(gemini5h?.usedPercent == 100) // 1 - 0.0
        let claudeWeek = snapshot.windows.first { $0.label == "Claude and GPT models" && $0.kind == .week7d }
        #expect(claudeWeek?.usedPercent == 34) // 1 - 0.66 = 34%
        let claude5h = snapshot.windows.first { $0.label == "Claude and GPT models" && $0.kind == .session5h }
        #expect(claude5h?.usedPercent == 0) // 1 - 1.0
        // Flat vs nested extraction: the live-4windows fixture uses flat remainingFraction,
        // the legacy fixture uses nested remaining.remainingFraction — both must map.
        let usesFlat = snapshot.windows.contains { $0.usedPercent == 100 }
        #expect(usesFlat)
    }

    @Test func unauthorizedOn401WithReconnectMessage() async throws {
        let stub = StubSession()
        stub.respond { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                // Refresh attempted but server says invalid_grant
                return .init(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8), headers: [:])
            }
            if url.contains("retrieveUserQuotaSummary") {
                return .init(status: 401, data: Data(), headers: [:])
            }
            return .init(status: 599, data: Data(), headers: [:])
        }
        // Stale pi token but refresh will 400 → should surface reconnect, not hidden
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-per13-401-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let piFile = dir.appendingPathComponent("auth.json")
        let pastMillis = Int(Date().timeIntervalSince1970 * 1000) - 600_000
        try Data("""
        {"antigravity": {"type": "oauth", "access": "stale-pi", "refresh": "bad-refresh", "expires": \(pastMillis)}}
        """.utf8).write(to: piFile)
        let piAuth = FilePiAuthSource(explicitPath: piFile)
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: piAuth,
                                           refresher: GoogleAntigravityOAuthRefresher(session: stub.session, client: testAntigravityOAuthClient))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            if case .unauthorized(let detail) = error {
                #expect(detail?.contains("Reconnect") == true, "must be Reconnect in Settings, got \(String(describing: detail))")
                #expect(detail?.contains("Auth expired") == true)
            } else {
                Issue.record("expected unauthorized, got \(error)")
            }
        }
    }

    @Test func unauthorizedWithoutRefreshTokenShowsReconnect() async throws {
        let stub = StubSession()
        stub.respond { request in
            if request.url?.absoluteString.contains("retrieveUserQuotaSummary") == true {
                return .init(status: 401, data: Data(), headers: [:])
            }
            return .init(status: 599, data: Data(), headers: [:])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-per13-norefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let piFile = dir.appendingPathComponent("auth.json")
        // Token has no refresh token and will 401
        try Data("""
        {"antigravity": {"type": "oauth", "access": "stale-no-refresh", "expires": \(Int(Date().timeIntervalSince1970 * 1000) - 600000)}}
        """.utf8).write(to: piFile)
        let piAuth = FilePiAuthSource(explicitPath: piFile)
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: piAuth,
                                           refresher: GoogleAntigravityOAuthRefresher(session: stub.session, client: testAntigravityOAuthClient))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            if case .unauthorized(let detail) = error {
                #expect(detail?.contains("Reconnect") == true)
            } else {
                Issue.record("expected unauthorized")
            }
        }
    }

    @Test func piRefreshDoesNotWriteToPiFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-per13-nowrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let piFile = dir.appendingPathComponent("auth.json")
        let pastMillis = Int(Date().timeIntervalSince1970 * 1000) - 600_000
        let original = """
        {"antigravity": {"type": "oauth", "access": "stale-pi", "refresh": "pi-refresh-live", "expires": \(pastMillis)}}
        """
        try Data(original.utf8).write(to: piFile)
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: piFile.path)
        let modBefore = attrsBefore[.modificationDate] as? Date

        let stub = StubSession()
        stub.respond { request in
            if request.url?.absoluteString == "https://oauth2.googleapis.com/token" {
                return .ok(Data(#"{"access_token": "fresh-token", "expires_in": 3600}"#.utf8))
            }
            return .ok(try Fixtures.load("antigravity-quota-live-4windows"))
        }
        let piAuth = FilePiAuthSource(explicitPath: piFile)
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: piAuth,
                                           refresher: GoogleAntigravityOAuthRefresher(session: stub.session, client: testAntigravityOAuthClient))
        _ = try await provider.fetchUsage()
        let dataAfter = try Data(contentsOf: piFile)
        #expect(String(data: dataAfter, encoding: .utf8) == original, "Pi file must not be mutated in-memory refresh")
        if let modBefore {
            let attrsAfter = try FileManager.default.attributesOfItem(atPath: piFile.path)
            let modAfter = attrsAfter[.modificationDate] as? Date
            #expect(modAfter == modBefore)
        }
    }

    @Test func reactive401RefreshRetryThenSucceeds() async throws {
        // Token looks fresh (future expiry) but server 401s — provider should
        // try one reactive refresh with the stored refresh token and retry.
        let stub = StubSession()
        var tokenCalls = 0
        var quotaCalls = 0
        stub.respond { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://oauth2.googleapis.com/token" {
                tokenCalls += 1
                return .ok(Data(#"{"access_token": "reactive-fresh", "expires_in": 3600}"#.utf8))
            }
            if url.contains("retrieveUserQuotaSummary") {
                quotaCalls += 1
                if quotaCalls == 1 {
                    // First quota call with stale-but-looks-fresh token → 401
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-looking-stale")
                    return .init(status: 401, data: Data(), headers: [:])
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer reactive-fresh")
                return .ok(try Fixtures.load("antigravity-quota-live-4windows"))
            }
            return .init(status: 599, data: Data(), headers: [:])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-per13-reactive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let piFile = dir.appendingPathComponent("auth.json")
        let futureMillis = Int(Date().timeIntervalSince1970 * 1000) + 3_600_000 // fresh for 1h
        try Data("""
        {"antigravity": {"type": "oauth", "access": "fresh-looking-stale", "refresh": "pi-refresh-reactive", "expires": \(futureMillis)}}
        """.utf8).write(to: piFile)
        let piAuth = FilePiAuthSource(explicitPath: piFile)
        let provider = AntigravityProvider(session: stub.session, localSession: stub.session,
                                           probe: StubLSProbe(nil),
                                           keychainReader: StubKeychain(nil),
                                           piAuth: piAuth,
                                           refresher: GoogleAntigravityOAuthRefresher(session: stub.session, client: testAntigravityOAuthClient))
        let snapshot = try await provider.fetchUsage()
        #expect(tokenCalls == 1)
        #expect(quotaCalls == 2)
        #expect(snapshot.windows.count == 4)
    }
}

// Reuse stubs from AntigravityProviderTests — define locally if not visible.
private final class StubLSProbe: AntigravityLanguageServerProbe, @unchecked Sendable {
    let result: AntigravityLanguageServer?
    init(_ result: AntigravityLanguageServer?) { self.result = result }
    func locateLanguageServer() async -> AntigravityLanguageServer? { result }
}
private struct StubKeychain: AntigravityKeychainReader {
    let creds: AntigravityOAuthCredentials?
    init(_ creds: AntigravityOAuthCredentials?) { self.creds = creds }
    func readCredentials() async throws -> AntigravityOAuthCredentials? { creds }
}
