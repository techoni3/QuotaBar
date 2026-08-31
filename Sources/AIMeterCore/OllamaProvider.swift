import Foundation

/// Local Ollama daemon. This is NOT a subscription with a server-side quota —
/// the row renders as "local — no subscription quota" with `ProviderStatus.local`.
///
/// `GET /api/ps` returns loaded models (`{"models":[{"name":"llama3.2:3b",…}]}`);
/// `GET /api/tags` returns the full installed model list. Either being reachable
/// proves the daemon is up; the model names are surfaced as labels.
public struct OllamaProvider: AIProvider {
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    public let id = ProviderID("ollama")
    public let displayName = "Ollama"

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = OllamaProvider.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let models: [String]
        do {
            models = try await loadedModels()
        } catch {
            // /api/ps can 404 on very old daemons; /api/tags is the fallback
            // existence probe.
            do {
                models = try await installedModels()
            } catch {
                throw ProviderError.unavailable("Ollama not running at \(baseURL.host ?? "localhost"):\(baseURL.port ?? 11434)")
            }
        }
        return UsageSnapshot(
            planName: "local — no subscription quota",
            windows: models.map { UsageWindow(kind: .credits, usedPercent: 0, resetsAt: nil, label: $0) },
            fetchedAt: Date(),
            status: .local
        )
    }

    private func loadedModels() async throws -> [String] {
        let response = try await HTTPOps.send(makeRequest("/api/ps"), session: session)
        let data = try response.validated()
        guard let models = Self.decodeModels(data) else {
            throw ProviderError.unavailable("unexpected Ollama /api/ps payload")
        }
        return models
    }

    private func installedModels() async throws -> [String] {
        let response = try await HTTPOps.send(makeRequest("/api/tags"), session: session)
        let data = try response.validated()
        guard let models = Self.decodeModels(data) else {
            throw ProviderError.unavailable("unexpected Ollama /api/tags payload")
        }
        return models
    }

    private func makeRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return request
    }

    private struct ListResponse: Decodable {
        let models: [Model]?
    }
    private struct Model: Decodable {
        let name: String?
    }

    /// Returns nil when the payload isn't valid Ollama JSON; a valid payload
    /// with an absent/empty model list decodes to [] (daemon up, nothing loaded).
    private static func decodeModels(_ data: Data) -> [String]? {
        guard let list = try? JSONDecoder().decode(ListResponse.self, from: data) else { return nil }
        return (list.models ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
    }
}