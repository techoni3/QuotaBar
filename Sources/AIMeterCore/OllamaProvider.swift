import Foundation

/// Local Ollama daemon. This is NOT a subscription with a server-side quota —
/// the row renders as "local — no subscription quota" with `ProviderStatus.local`.
///
/// `GET /api/ps` returns loaded models (`{"models":[{"name":"llama3.2:3b",…}]}`);
/// `GET /api/tags` returns the full installed model list. Either being reachable
/// proves the daemon is up; the model names are surfaced as labels.
public struct OllamaProvider: AIProvider {
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!
    /// Provider id used in Pi's credential file for the ollama.com cloud login.
    public static let cloudProviderID = "ollama"

    public let id = ProviderID("ollama")
    public let displayName = "Ollama"

    private let baseURL: URL
    private let session: URLSession
    private let cloudAuth: (any PiAuthReading)?

    /// - Parameter cloudAuth: optional Pi credential reader; when it yields an
    ///   ollama key the row reports the cloud account instead of the local
    ///   daemon (Pi's ollama key is API-key auth to ollama.com's cloud — no
    ///   public quota endpoint, so we only surface "connected").
    public init(baseURL: URL = OllamaProvider.defaultBaseURL,
                session: URLSession = .shared,
                cloudAuth: (any PiAuthReading)? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.cloudAuth = cloudAuth
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        // Pi OAuth'd cloud (ollama.com): the key proves the account is linked.
        // No public quota endpoint — surface the two windows that Pi's cloud
        // session normally reports, at 0% ("connected", never "Not connected").
        if let key = cloudAuth?.apiKey(for: Self.cloudProviderID), !key.isEmpty {
            return UsageSnapshot(
                planName: "Ollama Cloud — connected",
                windows: [
                    UsageWindow(kind: .session5h, usedPercent: 0, resetsAt: nil, label: "Cloud session (5h)"),
                    UsageWindow(kind: .week7d, usedPercent: 0, resetsAt: nil, label: "Cloud weekly"),
                ],
                fetchedAt: Date(),
                status: .ok
            )
        }
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