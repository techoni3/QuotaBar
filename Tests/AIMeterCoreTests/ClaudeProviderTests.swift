import Foundation
import Testing
@testable import AIMeterCore

struct ClaudeProviderTests {
    @Test func parsesFixtureWindowsAndPlan() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("claude-usage")) }
        let provider = ClaudeProvider(session: stub.session,
                                      tokenSource: StubClaudeTokenSource(token: "test-token"))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == "Claude Max 20x")
        #expect(snapshot.windows.count == 4)

        let session = snapshot.windows.first { $0.kind == .session5h }
        #expect(session?.usedPercent == 27) // 27.4 rounds to 27
        #expect(session?.label == nil)
        #expect(session?.resetsAt != nil)

        let week = snapshot.windows.first { $0.kind == .week7d && $0.label == nil }
        #expect(week?.usedPercent == 19) // 18.6 rounds to 19

        let opus = snapshot.windows.first { $0.label == "Opus" }
        #expect(opus?.usedPercent == 91)
        #expect(opus?.tint == .red)

        let extra = snapshot.windows.first { $0.kind == .month }
        #expect(extra?.usedPercent == 20) // 7/35
    }

    @Test func minimalFixtureHasNoPlanAndTwoWindows() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("claude-usage-minimal")) }
        let provider = ClaudeProvider(session: stub.session,
                                      tokenSource: StubClaudeTokenSource(token: "test-token"))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == nil)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.usedPercent == 3)
        #expect(snapshot.windows.last?.usedPercent == 56) // 55.5 rounds to 56
    }

    @Test func sendsOAuthHeaders() async throws {
        let stub = StubSession()
        stub.respond { _ in .ok(try Fixtures.load("claude-usage-minimal")) }
        let provider = ClaudeProvider(session: stub.session,
                                      tokenSource: StubClaudeTokenSource(token: "tok-123"))

        _ = try await provider.fetchUsage()

        let request = try #require(stub.requests().first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func http401BecomesUnauthorized() async {
        let stub = StubSession()
        stub.respond { _ in .init(status: 401, data: Data(), headers: [:]) }
        let provider = ClaudeProvider(session: stub.session,
                                      tokenSource: StubClaudeTokenSource(token: "expired"))

        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            #expect(error.isRetryable == false)
            if case .unauthorized = error {} else {
                Issue.record("expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func garbagePayloadBecomesUnavailable() async {
        let stub = StubSession()
        stub.respond { _ in .ok(Data("not json".utf8)) }
        let provider = ClaudeProvider(session: stub.session,
                                      tokenSource: StubClaudeTokenSource(token: "t"))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            #expect(error.isRetryable)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func planInference() {
        // Max multiplier in the tier wins (carries extra info).
        #expect(ClaudeUsageResponse.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Claude Max 20x")
        #expect(ClaudeUsageResponse.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Claude Max 5x")
        // subscriptionType preferred over plain tier.
        #expect(ClaudeUsageResponse.planName(subscriptionType: "pro", rateLimitTier: "default_claude_pro") == "Claude Pro")
        // Tier fallback when no type.
        #expect(ClaudeUsageResponse.planName(subscriptionType: nil, rateLimitTier: "default_claude_team") == "Claude Team")
        // Unknown values pass through capitalized.
        #expect(ClaudeUsageResponse.planName(subscriptionType: "mystery", rateLimitTier: nil) == "Mystery")
        #expect(ClaudeUsageResponse.planName(subscriptionType: nil, rateLimitTier: nil) == nil)
    }

    @Test func compositeTokenSourcePrefersLiveKeychainThenVault() async throws {
        let vault = InMemoryCredentialVault()
        try vault.storeToken("imported-token", for: ProviderID("claude"))

        let source = CompositeClaudeTokenSource([
            FailingTokenSource(error: .unauthorized(detail: "no keychain entry")),
            VaultClaudeTokenSource(vault: vault, providerID: ProviderID("claude")),
        ])
        #expect(try await source.accessToken() == "imported-token")

        // If both fail, the last error surfaces.
        let failing = CompositeClaudeTokenSource([
            FailingTokenSource(error: .unauthorized(detail: "denied")),
            FailingTokenSource(error: .unauthorized(detail: "no import")),
        ])
        do {
            _ = try await failing.accessToken()
            Issue.record("expected unauthorized")
        } catch let error as ProviderError {
            #expect(error == .unauthorized(detail: "no import"))
        }
    }
}

private struct FailingTokenSource: ClaudeTokenSource {
    let error: ProviderError
    func accessToken() async throws -> String { throw error }
}
