import Foundation
import Testing
@testable import AIMeterCore

struct CredentialVaultTests {
    @Test func inMemoryVaultRoundTrip() throws {
        let vault = InMemoryCredentialVault()
        let id = ProviderID("claude")

        #expect(vault.fetchToken(for: id) == nil)
        try vault.storeToken("tok-1", for: id)
        #expect(vault.fetchToken(for: id) == "tok-1")
        try vault.storeToken("tok-2", for: id) // overwrite
        #expect(vault.fetchToken(for: id) == "tok-2")
        vault.deleteToken(for: id)
        #expect(vault.fetchToken(for: id) == nil)
        vault.deleteToken(for: id) // idempotent
    }

    @Test func keychainVaultRoundTripInRealKeychain() throws {
        // Exercises the real SecItem path under AIMeter's own service
        // namespace (safe: app-local generic password, device-only).
        let vault = KeychainCredentialVault()
        let id = ProviderID("vault-selftest")
        defer { vault.deleteToken(for: id) }

        vault.deleteToken(for: id)
        #expect(vault.fetchToken(for: id) == nil)
        try vault.storeToken("secret-1", for: id)
        #expect(vault.fetchToken(for: id) == "secret-1")
        try vault.storeToken("secret-2", for: id) // update path
        #expect(vault.fetchToken(for: id) == "secret-2")
        vault.deleteToken(for: id)
        #expect(vault.fetchToken(for: id) == nil)
    }

    @Test func keychainVaultIsolatesPerProvider() throws {
        let vault = KeychainCredentialVault()
        let a = ProviderID("vault-iso-a")
        let b = ProviderID("vault-iso-b")
        defer { vault.deleteToken(for: a); vault.deleteToken(for: b) }

        try vault.storeToken("a-token", for: a)
        try vault.storeToken("b-token", for: b)
        #expect(vault.fetchToken(for: a) == "a-token")
        #expect(vault.fetchToken(for: b) == "b-token")
    }
}

struct UsageRefresherTests {
    /// Thread-safe mutable result holder (locks are confined to sync methods).
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<UsageSnapshot, ProviderError>

        init(_ value: Result<UsageSnapshot, ProviderError>) {
            self.value = value
        }

        func get() -> Result<UsageSnapshot, ProviderError> {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set(_ value: Result<UsageSnapshot, ProviderError>) {
            lock.lock(); defer { lock.unlock() }
            self.value = value
        }
    }

    private final class StubProvider: AIProvider, @unchecked Sendable {
        let id: ProviderID
        let displayName: String
        private let box: ResultBox

        init(id: String, result: Result<UsageSnapshot, ProviderError>) {
            self.id = ProviderID(id)
            self.displayName = id.capitalized
            self.box = ResultBox(result)
        }

        func fetchUsage() async throws -> UsageSnapshot {
            switch box.get() {
            case .success(let snapshot): return snapshot
            case .failure(let error): throw error
            }
        }

        func set(_ result: Result<UsageSnapshot, ProviderError>) {
            box.set(result)
        }
    }

    private static func snapshot(percent: Int) -> UsageSnapshot {
        UsageSnapshot(planName: "Test Plan",
                      windows: [UsageWindow(kind: .session5h, usedPercent: percent)],
                      fetchedAt: Date())
    }

    /// Awaits the next state the refresher publishes. The stream is buffered
    /// (.bufferingNewest(1)) so first() resolves immediately once a state has
    /// been published; call this only AFTER a refresh/start trigger so it never
    /// deadlocks waiting on a stream that has not produced yet.
    private static func firstState(_ refresher: UsageRefresher) async -> RefresherState {
        await refresher.updates.first(where: { _ in true }) ?? .empty
    }

    /// Awaits the first published state satisfying `match`.
    private static func firstWhere(_ refresher: UsageRefresher,
                                   _ match: @escaping (RefresherState) -> Bool) async -> RefresherState {
        await refresher.updates.first(where: match) ?? .empty
    }

    /// A unique, throwaway UserDefaults suite per test so provider enabled-flag
    /// writes never leak into (or out of) the real standard defaults — the app
    /// reads those same keys at runtime, and stale values between runs caused
    /// silent refresh skips.
    private static func isolatedDefaults() -> (UserDefaults, String) {
        let name = "aimeter-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (suite, name)
    }

    @Test func refreshAllPublishesSuccessAndFailsSoftly() async {
        let ok = StubProvider(id: "ok", result: .success(Self.snapshot(percent: 10)))
        let broken = StubProvider(id: "broken", result: .failure(.unavailable("boom")))
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let refresher = UsageRefresher(providers: [ok, broken], interval: 60, cacheURL: nil, defaultsSuiteName: suiteName)

        await refresher.refreshAll()

        // refreshAll() already published, so the buffered stream yields
        // immediately — no wall-clock wait.
        let published = await Self.firstState(refresher)
        #expect(published.results[ProviderID("ok")] != nil)

        let state = await refresher.currentState()
        guard case .success(let okSnapshot)? = state.results[ProviderID("ok")] else {
            Issue.record("expected success for 'ok'")
            return
        }
        #expect(okSnapshot.windows.first?.usedPercent == 10)
        guard case .failure(let brokenError)? = state.results[ProviderID("broken")] else {
            Issue.record("expected failure for 'broken'")
            return
        }
        #expect(brokenError == .unavailable("boom"))
    }

    @Test func cachePersistsAcrossRefresherInstances() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let provider = StubProvider(id: "cached", result: .success(Self.snapshot(percent: 77)))
        let first = UsageRefresher(providers: [provider], interval: 60, cacheURL: cacheURL, defaultsSuiteName: suiteName)
        await first.refreshAll()
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // A brand-new refresher (app relaunch) loads the cached snapshot
        // immediately for an instant cold start. start() fills state from the
        // disk cache; polling is disabled so a live fetch never races the read.
        let coldProvider = StubProvider(id: "cached", result: .failure(.unavailable("never called")))
        let second = UsageRefresher(providers: [coldProvider], interval: 60, cacheURL: cacheURL, defaultsSuiteName: suiteName)
        await second.setEnabled(ProviderID("cached"), false)
        await second.start()
        let coldState = await second.currentState()
        guard case .success(let cached)? = coldState.results[ProviderID("cached")] else {
            Issue.record("expected cached snapshot for cold start")
            return
        }
        #expect(cached.windows.first?.usedPercent == 77)
        await second.stop()
    }

    @Test func disabledProviderIsNotRefreshed() async {
        let provider = StubProvider(id: "off", result: .success(Self.snapshot(percent: 5)))
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let refresher = UsageRefresher(providers: [provider], interval: 60, cacheURL: nil, defaultsSuiteName: suiteName)

        await refresher.setEnabled(ProviderID("off"), false)
        await refresher.refreshAll() // must skip disabled providers

        let state = await refresher.currentState()
        #expect(state.results[ProviderID("off")] == nil)
        #expect(state.enabled[ProviderID("off")] == false)
    }

    @Test func errorsSurfaceVerbatim() async {
        let rateLimited = StubProvider(id: "rl", result: .failure(.rateLimited(retryAfter: 30)))
        let unauthorized = StubProvider(id: "ua", result: .failure(.unauthorized(detail: nil)))
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let refresher = UsageRefresher(providers: [rateLimited, unauthorized], interval: 60, cacheURL: nil, defaultsSuiteName: suiteName)

        await refresher.refreshAll()

        let state = await refresher.currentState()
        guard case .failure(let rlError)? = state.results[ProviderID("rl")] else {
            Issue.record("expected failure for 'rl'")
            return
        }
        #expect(rlError.isRetryable == true) // backoff will engage
        guard case .failure(let uaError)? = state.results[ProviderID("ua")] else {
            Issue.record("expected failure for 'ua'")
            return
        }
        #expect(uaError.isRetryable == false) // no backoff for auth errors
    }

    @Test func successResetsFailureState() async {
        let provider = StubProvider(id: "flaky", result: .failure(.unavailable("down")))
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let refresher = UsageRefresher(providers: [provider], interval: 60, cacheURL: nil, defaultsSuiteName: suiteName)

        await refresher.refreshAll()

        provider.set(.success(Self.snapshot(percent: 42)))
        await refresher.refreshAll()

        let state = await refresher.currentState()
        guard case .success(let snapshot)? = state.results[ProviderID("flaky")] else {
            Issue.record("expected success after recovery")
            return
        }
        #expect(snapshot.windows.first?.usedPercent == 42)
    }

    @Test func providerMetadataSurfacesInState() async {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let provider = StubProvider(id: "meta", result: .success(Self.snapshot(percent: 1)))
        let refresher = UsageRefresher(providers: [provider], interval: 60, cacheURL: nil, defaultsSuiteName: suiteName)
        let state = await refresher.currentState()
        #expect(state.providers.count == 1)
        #expect(state.providers.first?.displayName == "Meta")
        #expect(state.enabled[ProviderID("meta")] == true)
    }

    @Test func pollingLoopFiresAndCanBeCancelled() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let provider = StubProvider(id: "poll", result: .success(Self.snapshot(percent: 33)))
        let refresher = UsageRefresher(providers: [provider], interval: 5, cacheURL: nil, defaultsSuiteName: suiteName)

        await refresher.start()

        // start() publishes an initial (empty) state, then the runLoop polls
        // once and publishes a state carrying the result. Wait for the
        // result-bearing state on the buffered stream — resolves
        // deterministically with no wall-clock dependence — proving the loop
        // really fires on its own interval.
        let state = await Self.firstWhere(refresher) { $0.results[ProviderID("poll")] != nil }
        guard case .success(let polled)? = state.results[ProviderID("poll")] else {
            Issue.record("expected polled success")
            return
        }
        #expect(polled.windows.first?.usedPercent == 33)

        // Cancelling the stored polling task lets the process exit cleanly
        // (no runaway timer keeps the test host alive).
        await refresher.stop()
    }
}
