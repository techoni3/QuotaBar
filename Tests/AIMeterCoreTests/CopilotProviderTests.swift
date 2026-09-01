import Foundation
import Testing
@testable import AIMeterCore

struct CopilotProviderTests {
    // MARK: - Helpers

    private static func makePiAuthFile(copilotToken: String? = "ghu_test_token") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-copilot-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        var entries: [String: Any] = ["_comment": "test"]
        if let token = copilotToken {
            entries["github-copilot"] = ["type": "oauth", "access": token, "refresh": "rt-1", "expires": 9_999_999_999_000.0]
        } else {
            entries["openrouter"] = ["type": "api", "key": "sk-or-not-copilot"]
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: url)
        return url
    }

    private static func piAuthWithToken(_ token: String?) throws -> FilePiAuthSource {
        let url = try makePiAuthFile(copilotToken: token)
        return FilePiAuthSource(explicitPath: url)
    }

    private static func provider(piAuth: FilePiAuthSource, stub: StubSession) -> CopilotProvider {
        CopilotProvider(session: stub.session, piAuth: piAuth)
    }

    // MARK: - apiKey present -> .ok with windows

    @Test func apiKeyPresentReturnsOkWithWindows() async throws {
        let piAuth = try Self.piAuthWithToken("ghu_test_token")
        let stub = StubSession()
        stub.respond { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_test_token")
            #expect(request.url?.absoluteString.contains("api.github.com") == true || request.url?.absoluteString.contains("proxy.business.githubcopilot.com") == true)
            // Quota payload that our decoder maps to 1-2 windows.
            let payload = #"{"quota":{"percent":42,"resetsAt":"2030-01-01T00:00:00Z"},"weekly":{"percent":73}}"#
            return .ok(Data(payload.utf8))
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count >= 1 && snapshot.windows.count <= 3)
        #expect(snapshot.windows.contains { $0.usedPercent == 42 })
        // Never hits proxy if first succeeds.
        #expect(stub.requests().count == 1)
    }

    @Test func quotaWithLimitUsedMapsToPercent() async throws {
        let piAuth = try Self.piAuthWithToken("ghu_limit")
        let stub = StubSession()
        stub.respond { _ in
            .ok(Data(#"{"quota":{"limit":100,"used":30}}"#.utf8))
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.first?.usedPercent == 30)
    }

    // MARK: - 401 -> unauthorized with Reconnect

    @Test func unauthorized401BecomesReconnect() async {
        let piAuth = try! Self.piAuthWithToken("ghu_expired")
        let stub = StubSession()
        stub.respond { _ in .init(status: 401, data: Data(), headers: [:]) }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            #expect(error.isRetryable == false)
            if case .unauthorized(let detail) = error {
                #expect(detail?.contains("Reconnect") == true || detail?.contains("Auth expired") == true)
                #expect(error.displayText.contains("Not connected") || detail?.contains("Reconnect") == true)
            } else {
                Issue.record("expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    // MARK: - No key -> unauthorized Not connected, never hits network

    @Test func noKeyIsUnauthorizedAndNoNetworkHit() async {
        let piAuth = try! Self.piAuthWithToken(nil) // no github-copilot entry
        let stub = StubSession()
        stub.respond { _ in
            Issue.record("should never hit network without key")
            return .ok(Data())
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            if case .unauthorized(let detail) = error {
                #expect(detail?.contains("Not connected") == true)
            } else {
                Issue.record("expected unauthorized, got \(error)")
            }
            #expect(stub.requests().isEmpty) // local never hits network without key
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Fallback when seat info only

    @Test func seatInfoOnlyFallsBackToBusinessSeatConnected() async throws {
        let piAuth = try Self.piAuthWithToken("ghu_seat")
        let stub = StubSession()
        stub.respond { _ in
            // Seat-only payload (no quota window) — valid JSON but no percent/limit.
            .ok(Data(#"{"seat_breakdown":{"active":1},"plan":"business"}"#.utf8))
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.status == .ok)
        #expect(snapshot.planName?.contains("Copilot") == true)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.usedPercent == 0)
        #expect(snapshot.planName?.contains("business seat") == true || snapshot.planName?.contains("Copilot") == true)
    }

    @Test func notFoundOnFirstEndpointTriesNext() async throws {
        let piAuth = try Self.piAuthWithToken("ghu_404")
        let stub = StubSession()
        var calls = 0
        stub.respond { request in
            calls += 1
            if request.url?.absoluteString.contains("api.github.com/copilot/billing") == true {
                return .init(status: 404, data: Data(), headers: [:])
            }
            // Second endpoint succeeds
            return .ok(Data(#"{"quota":{"percent":55}}"#.utf8))
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.first?.usedPercent == 55)
        #expect(calls == 2)
    }

    // MARK: - Never logs tokens, never writes to ~/.pi (static checks via grep in acceptance, but also assert no file at pi path)

    @Test func doesNotWriteToPiFile() async throws {
        let piAuth = try Self.piAuthWithToken("ghu_nowrite")
        let stub = StubSession()
        stub.respond { _ in .ok(Data(#"{"quota":{"percent":10}}"#.utf8)) }
        let url = piAuth as FilePiAuthSource
        let before = try Data(contentsOf: url.path)
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        _ = try await provider.fetchUsage()
        let after = try Data(contentsOf: url.path)
        #expect(before == after) // never writes to ~/.pi
    }

    // MARK: - Snapshot decoding directly

    @Test func snapshotFromDataDecodesQuotaWindows() throws {
        let data = Data(#"{"quota":{"percent":42,"resetsAt":"2030-01-01T00:00:00Z"}}"#.utf8)
        let snapshot = try #require(CopilotProvider.snapshot(from: data))
        #expect(snapshot.windows.first?.usedPercent == 42)
    }
}
