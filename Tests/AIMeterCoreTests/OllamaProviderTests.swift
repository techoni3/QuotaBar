import Foundation
import Testing
@testable import AIMeterCore

struct OllamaProviderTests {
    @Test func psReachableSurfacesLocalStatus() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/api/ps")
            return .ok(try Fixtures.load("ollama-ps"))
        }
        let provider = OllamaProvider(session: stub.session)

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.status == .local)
        #expect(snapshot.planName == "local — no subscription quota")
        #expect(snapshot.windows.map(\.label) == ["llama3.2:3b"])
        #expect(snapshot.windows.allSatisfy { $0.usedPercent == 0 })
    }

    @Test func psFailureFallsBackToTags() async throws {
        let stub = StubSession()
        stub.respond { request in
            if request.url?.path == "/api/ps" {
                return .init(status: 500, data: Data(), headers: [:])
            }
            #expect(request.url?.path == "/api/tags")
            return .ok(try Fixtures.load("ollama-tags"))
        }
        let provider = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:8080")!, session: stub.session)

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.status == .local)
        #expect(snapshot.windows.map(\.label) == ["llama3.2:3b", "qwen3:8b"])
    }

    @Test func daemonDownIsUnavailable() async {
        let stub = StubSession()
        stub.respond { _ in .init(status: 404, data: Data(), headers: [:]) }
        let provider = OllamaProvider(session: stub.session)

        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            #expect(error.isRetryable)
            #expect(error.displayText.contains("Ollama not running"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func garbagePayloadBecomesUnavailable() async {
        let stub = StubSession()
        stub.respond { _ in .ok(Data("not json".utf8)) }
        let provider = OllamaProvider(session: stub.session)

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
struct OllamaCloudTests {
    @Test func cloudUsageFromFixtureMapsRealPercents() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.absoluteString == "https://ollama.com/api/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-pi-ollama")
            return .ok(try Fixtures.load("ollama-cloud-usage"))
        }
        let provider = OllamaProvider(session: stub.session,
                                      cloudAuth: FilePiAuthSource(explicitPath: Self.piFixtureURL()))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.status == .ok)
        #expect(snapshot.planName == "Ollama Cloud — connected")
        // 0.059 → 6%, 0.304 → 30% — REAL cloud numbers, not 0%.
        #expect(snapshot.windows.map(\.kind) == [.session5h, .week7d])
        #expect(snapshot.windows.map(\.usedPercent) == [6, 30])
        // Top consumers (up to 4) as label notes.
        #expect(snapshot.windows.first?.label?.contains("Cloud session (5h)") == true)
        #expect(snapshot.windows.first?.label?.contains("glm-5.3-flash×48") == true)
        #expect(snapshot.windows.last?.label?.contains("glm-5.3-flash×366, glm-5.3×87") == true)
        // Cloud branch never probed localhost.
        #expect(stub.requests().count == 1)
    }

    @Test func fractionMapsToPercentAndTintThresholds() throws {
        let payload = #"""
        {"limits": {"session": {"usage": 0.9}, "weekly": {"usage": 1.0}}}
        """#
        let usage = try JSONDecoder().decode(OllamaCloudUsage.self, from: Data(payload.utf8))
        let snapshot = OllamaProvider.cloudSnapshot(from: usage, fetchedAt: Date())
        #expect(snapshot.windows.map(\.usedPercent) == [90, 100])
        // ≥90 renders the exhausted (critical) tier — 1.0 is fully used.
        #expect(snapshot.windows.map(\.tint) == [.red, .red])
        #expect(OllamaProvider.clampedPercent(0.03) == 3)
        #expect(OllamaProvider.clampedPercent(0.005) == 1)
    }

    @Test func fractionClampedOutOfRange() {
        #expect(OllamaProvider.clampedPercent(1.5) == 100)
        #expect(OllamaProvider.clampedPercent(-0.5) == 0)
        #expect(OllamaProvider.clampedPercent(0.27) == 27)
    }

    @Test func topConsumersAreCappedAtFour() {
        var models: [OllamaCloudUsage.Model] = []
        for i in 1...6 { models.append(OllamaCloudUsage.Model(name: "m\(i)", requestCount: i)) }
        #expect(OllamaProvider.consumersText(models) == "m1×1, m2×2, m3×3, m4×4")
        #expect(OllamaProvider.consumersText(nil) == "")
        #expect(OllamaProvider.consumersText([OllamaCloudUsage.Model(name: nil, requestCount: 9)]) == "")
        #expect(OllamaProvider.consumersText([OllamaCloudUsage.Model(name: "x", requestCount: nil)]) == "x")
    }

    @Test func unauthorized401DegradesToStableFallback() async throws {
        let stub = StubSession()
        stub.respond { _ in .init(status: 401, data: Data(), headers: [:]) }
        let provider = OllamaProvider(session: stub.session, cloudAuth: Self.piAuthForTests())

        let snapshot = try await provider.fetchUsage() // must NOT throw

        #expect(snapshot.status == .ok) // row stays visible (keep-stable)
        #expect(snapshot.planName == "Ollama Cloud — connected")
        #expect(snapshot.windows.map(\.kind) == [.session5h, .week7d])
        #expect(snapshot.windows.allSatisfy { $0.usedPercent == 0 })
    }

    @Test func garbageCloudPayloadDegradesToStableFallback() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(Data("not json".utf8)) }
        let provider = OllamaProvider(session: stub.session, cloudAuth: Self.piAuthForTests())
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 2)
    }

    @Test func localOllamaNeverFetchesCloud() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url?.host != "ollama.com") // must never be hit
            return .ok(try Fixtures.load("ollama-ps"))
        }
        let provider = OllamaProvider(session: stub.session) // no cloudAuth

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.status == .local)
        #expect(stub.requests().allSatisfy { $0.url?.host != "ollama.com" })
    }

    private static func piFixtureURL() -> URL {
        Bundle.module.url(forResource: "pi-auth", withExtension: "json", subdirectory: "Fixtures")!
    }
    private static func piAuthForTests() -> FilePiAuthSource {
        FilePiAuthSource(explicitPath: piFixtureURL())
    }
}
