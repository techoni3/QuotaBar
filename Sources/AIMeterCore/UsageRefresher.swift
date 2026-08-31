import Foundation

/// The refresher's observable state, published to the UI on every change.
public struct RefresherState: Equatable, Sendable {
    public struct ProviderInfo: Equatable, Sendable {
        public let id: ProviderID
        public let displayName: String
    }

    public var providers: [ProviderInfo]
    public var results: [ProviderID: Result<UsageSnapshot, ProviderError>]
    public var enabled: [ProviderID: Bool]
    /// Last successful fetch time per provider — survives a later failure so
    /// the UI can show a stale-data notice with the last-success time.
    public var lastSuccessAt: [ProviderID: Date]

    public static let empty = RefresherState(providers: [], results: [:], enabled: [:], lastSuccessAt: [:])
}

public typealias ProviderResult = Result<UsageSnapshot, ProviderError>

/// Owns provider polling: per-provider timers with ±jitter, exponential
/// backoff on retryable failures, refresh-on-demand (HUD open / manual
/// button), and a disk cache for instant cold start (spec Decision 4).
public actor UsageRefresher {
    public static let backoffCap: TimeInterval = 600 // 10 minutes

    private let providers: [ProviderID: any AIProvider]
    private let order: [ProviderID]
    private let interval: TimeInterval
    private let jitterFraction: Double
    private let cacheURL: URL?
    private let defaults: UserDefaults

    private var results: [ProviderID: ProviderResult] = [:]
    private var enabled: [ProviderID: Bool] = [:]
    private var lastSuccessAt: [ProviderID: Date] = [:]
    private var failureAttempts: [ProviderID: Int] = [:]
    private var backoffUntil: [ProviderID: Date] = [:]
    private var loops: [ProviderID: Task<Void, Never>] = [:]
    private var started = false

    public nonisolated let updates: AsyncStream<RefresherState>
    private let continuation: AsyncStream<RefresherState>.Continuation

    public init(providers: [any AIProvider],
                interval: TimeInterval = 60,
                jitterFraction: Double = 0.1,
                cacheURL: URL? = UsageRefresher.defaultCacheURL,
                defaultsSuiteName: String? = nil) {
        var map: [ProviderID: any AIProvider] = [:]
        var order: [ProviderID] = []
        for provider in providers where map[provider.id] == nil {
            map[provider.id] = provider
            order.append(provider.id)
        }
        self.providers = map
        self.order = order
        self.interval = max(5, interval)
        self.jitterFraction = jitterFraction
        self.cacheURL = cacheURL
        // Create the defaults store inside the actor (never receive one across
        // the boundary): a named suite isolates tests from the real app state.
        self.defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard

        (updates, continuation) = AsyncStream.makeStream(of: RefresherState.self, bufferingPolicy: .bufferingNewest(1))

        for id in order {
            let key = Self.enabledKey(for: id)
            enabled[id] = defaults.object(forKey: key) as? Bool ?? true
        }
    }

    /// Application Support/AIMeter/cache.json
    public static var defaultCacheURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("AIMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    private static func enabledKey(for id: ProviderID) -> String { "provider.enabled.\(id.rawValue)" }

    // MARK: - Lifecycle

    public func start() async {
        guard !started else { return }
        started = true
        if results.isEmpty {
            results = Self.initialResults(cacheURL: cacheURL)
        }
        publish()
        for id in order where enabled[id] == true {
            loops[id] = Task { [weak self] in
                await self?.runLoop(for: id)
            }
        }
    }

    public func stop() {
        for task in loops.values { task.cancel() }
        loops.removeAll()
        started = false
    }

    private func runLoop(for id: ProviderID) async {
        while !Task.isCancelled {
            await pollOnce(id)
            let delay = await nextLoopDelay(for: id)
            do {
                try await Task.sleep(for: .seconds(max(1, delay)))
            } catch {
                return // cancelled
            }
        }
    }

    /// Called on the actor after a poll: base interval ± jitter, extended to
    /// cover any active backoff window.
    private func nextLoopDelay(for id: ProviderID) -> TimeInterval {
        let jitter = interval * jitterFraction * (2 * Double.random(in: 0...1) - 1)
        let base = interval + jitter
        if let until = backoffUntil[id] {
            let remaining = until.timeIntervalSinceNow
            if remaining > base { return remaining }
        }
        return base
    }

    /// Timed poll: skipped while the provider is backing off or disabled.
    private func pollOnce(_ id: ProviderID) async {
        guard enabled[id] == true else { return }
        if let until = backoffUntil[id], until > Date() { return }
        await refresh(id, respectingBackoff: true)
    }

    // MARK: - Manual / on-demand refresh (HUD open, refresh button)

    /// Refreshes all enabled providers immediately, ignoring backoff windows
    /// (manual and HUD-open refreshes are always honored — spec Decision 4).
    public func refreshAll() async {
        for id in order where enabled[id] == true {
            await refresh(id, respectingBackoff: false)
        }
    }

    public func refresh(_ id: ProviderID) async {
        guard enabled[id] == true else { return }
        await refresh(id, respectingBackoff: false)
    }

    private func refresh(_ id: ProviderID, respectingBackoff: Bool) async {
        guard respectingBackoff == false || backoffUntil[id] == nil || backoffUntil[id]! <= Date(),
              let provider = providers[id]
        else { return }
        do {
            let snapshot = try await provider.fetchUsage()
            results[id] = .success(snapshot)
            lastSuccessAt[id] = snapshot.fetchedAt
            failureAttempts[id] = 0
            backoffUntil[id] = nil
            writeCache(id: id, snapshot: snapshot)
        } catch let error as ProviderError {
            recordFailure(id: id, error: error)
        } catch {
            recordFailure(id: id, error: .unavailable(error.localizedDescription))
        }
        publish()
    }

    private func recordFailure(id: ProviderID, error: ProviderError) {
        results[id] = .failure(error)
        guard error.isRetryable else { return }
        let attempt = (failureAttempts[id] ?? 0) + 1
        failureAttempts[id] = attempt
        backoffUntil[id] = Date().addingTimeInterval(Self.backoffDelay(attempt: attempt, base: interval))
    }

    /// Exponential backoff: base, 2·base, 4·base, … capped at 10 minutes.
    public static func backoffDelay(attempt: Int, base: TimeInterval, cap: TimeInterval = UsageRefresher.backoffCap) -> TimeInterval {
        guard attempt > 0 else { return base }
        return min(cap, base * pow(2, Double(attempt - 1)))
    }

    // MARK: - Enable/disable (persisted per provider)

    public func setEnabled(_ id: ProviderID, _ isEnabled: Bool) async {
        enabled[id] = isEnabled
        defaults.set(isEnabled, forKey: Self.enabledKey(for: id))
        if !isEnabled {
            backoffUntil[id] = nil
            failureAttempts[id] = 0
        } else if loops[id] == nil, started {
            loops[id] = Task { [weak self] in
                await self?.runLoop(for: id)
            }
            // Refresh right away so an enabled provider doesn't wait a full interval.
            await refresh(id, respectingBackoff: false)
        }
        publish()
    }

    // MARK: - State

    public func currentState() -> RefresherState {
        RefresherState(providers: order.map { .init(id: $0, displayName: providers[$0]?.displayName ?? $0.rawValue) },
                       results: results,
                       enabled: enabled,
                       lastSuccessAt: lastSuccessAt)
    }

    private func publish() {
        continuation.yield(currentState())
    }

    private struct CacheFile: Codable {
        var entries: [String: CacheEntry]
    }

    // MARK: - Disk cache (instant cold start)

    private struct CacheEntry: Codable {
        let snapshot: UsageSnapshot
    }

    private nonisolated static func initialResults(cacheURL: URL?) -> [ProviderID: ProviderResult] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return [:] }
        guard let file = try? JSONDecoder.flexibleISO8601.decode(CacheFile.self, from: data) else { return [:] }
        var out: [ProviderID: ProviderResult] = [:]
        for (key, entry) in file.entries {
            out[ProviderID(key)] = .success(entry.snapshot)
        }
        return out
    }

    private nonisolated func writeCache(id: ProviderID, snapshot: UsageSnapshot) {
        guard let cacheURL else { return }
        var file = CacheFile(entries: [:])
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder.flexibleISO8601.decode(CacheFile.self, from: data) {
            file = decoded
        }
        file.entries[id.rawValue] = CacheEntry(snapshot: snapshot)
        // Must be the mirror of `initialResults`' flexibleISO8601 decoder, or
        // Dates (stored as ISO8601 strings) can't round-trip through the cache.
        if let data = try? JSONEncoder.flexibleISO8601.encode(file) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
