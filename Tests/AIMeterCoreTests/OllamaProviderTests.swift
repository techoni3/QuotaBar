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