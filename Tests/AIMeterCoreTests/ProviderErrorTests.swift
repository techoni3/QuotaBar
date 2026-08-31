import Foundation
import Testing
@testable import AIMeterCore

struct ProviderErrorTests {
    @Test func http401MapsToUnauthorized() {
        #expect(ProviderError.http(status: 401, retryAfter: nil) == .unauthorized(detail: "HTTP 401"))
        #expect(ProviderError.http(status: 403, retryAfter: nil) == .unauthorized(detail: "HTTP 403"))
    }

    @Test func http429MapsToRateLimitedWithRetryAfter() {
        #expect(ProviderError.http(status: 429, retryAfter: 12) == .rateLimited(retryAfter: 12))
        #expect(ProviderError.http(status: 429, retryAfter: nil) == .rateLimited(retryAfter: nil))
    }

    @Test func http5xxMapsToUnavailable() {
        #expect(ProviderError.http(status: 500, retryAfter: nil) == .unavailable("HTTP 500"))
        #expect(ProviderError.http(status: 503, retryAfter: nil) == .unavailable("HTTP 503"))
    }

    @Test func otherCodesMapToUnavailable() {
        #expect(ProviderError.http(status: 404, retryAfter: nil) == .unavailable("HTTP 404"))
    }

    @Test func retryableFlags() {
        #expect(ProviderError.rateLimited(retryAfter: nil).isRetryable)
        #expect(ProviderError.unavailable("x").isRetryable)
        #expect(!ProviderError.unauthorized(detail: nil).isRetryable)
        #expect(!ProviderError.notInstalled.isRetryable)
        #expect(!ProviderError.invalidCredentials.isRetryable)
    }

    @Test func backoffIsExponentialAndCapped() {
        #expect(UsageRefresher.backoffDelay(attempt: 1, base: 60) == 60)
        #expect(UsageRefresher.backoffDelay(attempt: 2, base: 60) == 120)
        #expect(UsageRefresher.backoffDelay(attempt: 3, base: 60) == 240)
        #expect(UsageRefresher.backoffDelay(attempt: 10, base: 60) == 600) // capped at 10 min
        #expect(UsageRefresher.backoffDelay(attempt: 0, base: 60) == 60)
    }
}

struct ModelAdditionTests {
    @Test func labelRoundTripsThroughCodable() throws {
        let window = UsageWindow(kind: .week7d, usedPercent: 42, resetsAt: nil, label: "Opus")
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(UsageWindow.self, from: data)
        #expect(decoded == window)
        #expect(decoded.label == "Opus")
        #expect(decoded.title == "Opus")
    }

    @Test func legacyCacheWithoutLabelStillDecodes() throws {
        // Pre-M2 encoded snapshot (no label key) must remain decodable.
        let legacy = #"{"kind":"week7d","usedPercent":42}"#.data(using: .utf8)!
        let window = try JSONDecoder().decode(UsageWindow.self, from: legacy)
        #expect(window.label == nil)
        #expect(window.title == "Week (7d)")
    }

    @Test func countdownFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageWindow(kind: .session5h, usedPercent: 1, resetsAt: now.addingTimeInterval(3 * 3600 + 24 * 60))
            .resetCountdownText(now: now) == "resets in 3h 24m")
        #expect(UsageWindow(kind: .week7d, usedPercent: 1, resetsAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600))
            .resetCountdownText(now: now) == "resets in 2d 5h")
        #expect(UsageWindow(kind: .month, usedPercent: 1, resetsAt: now.addingTimeInterval(45 * 60))
            .resetCountdownText(now: now) == "resets in 45m")
        #expect(UsageWindow(kind: .month, usedPercent: 1, resetsAt: now.addingTimeInterval(-10))
            .resetCountdownText(now: now) == "resetting…")
        #expect(UsageWindow(kind: .month, usedPercent: 1, resetsAt: nil).resetCountdownText(now: now) == nil)
    }
}
