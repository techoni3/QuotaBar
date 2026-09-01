import Foundation
import Testing
@testable import AIMeterCore

struct OpenRouterProviderTests {
    private static func makePiAuthFile(openRouterKey: String? = "sk-or-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-openrouter-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        var entries: [String: Any] = ["_comment": "test"]
        if let key = openRouterKey {
            entries["openrouter"] = ["type": "api", "key": key]
        } else {
            entries["github-copilot"] = ["type": "oauth", "access": "ghu_not_openrouter"]
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: url)
        return url
    }

    private static func piAuthWithKey(_ key: String?) throws -> FilePiAuthSource {
        let url = try makePiAuthFile(openRouterKey: key)
        return FilePiAuthSource(explicitPath: url)
    }

    private static func provider(piAuth: FilePiAuthSource, stub: StubSession) -> OpenRouterProvider {
        OpenRouterProvider(session: stub.session, cloudAuth: piAuth)
    }

    // MARK: - apiKey present -> .ok with windows

    @Test func apiKeyPresentReturnsOkWithWindows() async throws {
        let piAuth = try Self.piAuthWithKey("sk-or-test-123")
        let stub = StubSession()
        stub.respond { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test-123")
            #expect(request.url?.absoluteString.contains("openrouter.ai") == true)
            // Credits shape: total_credits/total_usage
            let payload = #"{"data":{"total_credits":10,"total_usage":3}}"#
            return .ok(Data(payload.utf8))
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count >= 1 && snapshot.windows.count <= 2)
        #expect(snapshot.windows.first?.usedPercent == 30) // 3/10*100
        #expect(stub.requests().count == 1)
    }

    @Test func limitUsedMapsToWindows() async throws {
        let piAuth = try Self.piAuthWithKey("sk-or-limit")
        let stub = StubSession()
        stub.respond { _ in .ok(Data(#"{"data":{"limit":100,"usage":45}}"#.utf8)) }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.first?.usedPercent == 45)
    }

    @Test func authKeyEndpointFallbackOn404() async throws {
        let piAuth = try Self.piAuthWithKey("sk-or-fallback")
        let stub = StubSession()
        var calls = 0
        stub.respond { request in
            calls += 1
            if request.url?.absoluteString.contains("/credits") == true {
                return .init(status: 404, data: Data(), headers: [:])
            }
            // auth/key shape
            return .ok(Data(#"{"data":{"limit":200,"usage":100}}"#.utf8))
        }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.first?.usedPercent == 50)
        #expect(calls == 2)
    }

    // MARK: - 401 -> unauthorized with Reconnect

    @Test func unauthorized401BecomesReconnect() async {
        let piAuth = try! Self.piAuthWithKey("sk-or-expired")
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
            } else {
                Issue.record("expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - No key -> unauthorized Not connected, never hits network

    @Test func noKeyIsUnauthorizedAndNoNetworkHit() async {
        let piAuth = try! Self.piAuthWithKey(nil)
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
            #expect(stub.requests().isEmpty)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Fallback when no quota

    @Test func noQuotaFallsBackToConnected() async throws {
        let piAuth = try Self.piAuthWithKey("sk-or-nquota")
        let stub = StubSession()
        stub.respond { _ in .ok(Data(#"{"data":{"label":"my key"}}"#.utf8)) }
        let provider = Self.provider(piAuth: piAuth, stub: stub)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.usedPercent == 0)
        #expect(snapshot.planName?.contains("OpenRouter") == true)
    }

    // MARK: - piAuth alias init also works (ticket shows both cloudAuth/piAuth spellings)

    @Test func piAuthAliasInitWorks() async throws {
        let url = try Self.makePiAuthFile(openRouterKey: "sk-or-alias")
        let piAuth = FilePiAuthSource(explicitPath: url)
        let stub = StubSession()
        stub.respond { _ in .ok(Data(#"{"data":{"total_credits":5,"total_usage":1}}"#.utf8)) }
        let provider = OpenRouterProvider(session: stub.session, piAuth: piAuth)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.windows.first?.usedPercent == 20)
    }

    @Test func doesNotWriteToPiFile() async throws {
        let url = try Self.makePiAuthFile(openRouterKey: "sk-or-nowrite")
        let piAuth = FilePiAuthSource(explicitPath: url)
        let stub = StubSession()
        stub.respond { _ in .ok(Data(#"{"data":{"total_credits":10,"total_usage":2}}"#.utf8)) }
        let before = try Data(contentsOf: url)
        let provider = OpenRouterProvider(session: stub.session, cloudAuth: piAuth)
        _ = try await provider.fetchUsage()
        let after = try Data(contentsOf: url)
        #expect(before == after)
    }

    @Test func snapshotFromDataDecodesCredits() throws {
        let data = Data(#"{"data":{"total_credits":10,"total_usage":3}}"#.utf8)
        let snapshot = try #require(OpenRouterProvider.snapshot(from: data))
        #expect(snapshot.windows.first?.usedPercent == 30)
    }
}
