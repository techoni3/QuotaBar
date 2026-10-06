import Foundation
import Testing
@testable import AIMeterCore

// Synthetic application credentials only; never substitute real OAuth values.
let testAntigravityOAuthClient = AntigravityOAuthClient(
    clientID: "test-antigravity-client", clientSecret: "test-antigravity-secret"
)!

struct AntigravityOAuthClientTests {
    @Test func environmentLoadsCompleteConfiguration() throws {
        let client = try #require(AntigravityOAuthClient.fromEnvironment([
            "AIMETER_ANTIGRAVITY_CLIENT_ID": " test-client ",
            "AIMETER_ANTIGRAVITY_CLIENT_SECRET": " test-secret\n"
        ]))
        #expect(client.clientID == "test-client")
        #expect(client.clientSecret == "test-secret")
    }

    @Test func missingPartialOrBlankConfigurationIsRejected() {
        #expect(AntigravityOAuthClient.fromEnvironment([:]) == nil)
        #expect(AntigravityOAuthClient.fromEnvironment([
            "AIMETER_ANTIGRAVITY_CLIENT_ID": "test-client"
        ]) == nil)
        #expect(AntigravityOAuthClient.fromEnvironment([
            "AIMETER_ANTIGRAVITY_CLIENT_SECRET": "test-secret"
        ]) == nil)
        #expect(AntigravityOAuthClient(clientID: " ", clientSecret: "test-secret") == nil)
        #expect(AntigravityOAuthClient(clientID: "test-client", clientSecret: "\n") == nil)
    }

    @Test func missingConfigurationFailsBeforeNetworkRequest() async {
        let stub = StubSession()
        let refresher = GoogleAntigravityOAuthRefresher(session: stub.session, client: nil)
        do {
            _ = try await refresher.refresh(refreshToken: "test-refresh-token")
            Issue.record("Expected missing client configuration error")
        } catch let error as ProviderError {
            if case .unauthorized(let detail) = error {
                #expect(detail?.contains("CLIENT_ID") == true)
                #expect(detail?.contains("CLIENT_SECRET") == true)
            } else { Issue.record("Expected unauthorized") }
        } catch { Issue.record("Unexpected error type") }
        #expect(stub.requests().isEmpty)
    }

    @Test func injectedClientIsUsedForRefresh() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url == AntigravityProvider.oauthTokenURL)
            let body = request.aimeterBodyText ?? ""
            #expect(body.contains("client_id=test-antigravity-client"))
            #expect(body.contains("client_secret=test-antigravity-secret"))
            #expect(body.contains("refresh_token=test-refresh-token"))
            return .ok(Data(#"{"access_token":"test-new-access","expires_in":3600}"#.utf8))
        }
        let refresher = GoogleAntigravityOAuthRefresher(session: stub.session,
                                                       client: testAntigravityOAuthClient)
        let result = try await refresher.refresh(refreshToken: "test-refresh-token")
        #expect(result.accessToken == "test-new-access")
        #expect(stub.requests().count == 1)
    }

    @Test func freshCredentialCanFetchWithoutRefreshClient() async throws {
        let stub = StubSession()
        stub.respond { request in
            #expect(request.url != AntigravityProvider.oauthTokenURL)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
            return .ok(try Fixtures.load("antigravity-quota"))
        }
        let provider = AntigravityProvider(
            session: stub.session, localSession: stub.session, probe: NoLocalServer(),
            keychainReader: FreshCredential(),
            refresher: GoogleAntigravityOAuthRefresher(session: stub.session, client: nil)
        )
        let snapshot = try await provider.fetchUsage()
        #expect(!snapshot.windows.isEmpty)
        #expect(stub.requests().count == 1)
    }
}

private struct NoLocalServer: AntigravityLanguageServerProbe {
    func locateLanguageServer() async -> AntigravityLanguageServer? { nil }
}

private struct FreshCredential: AntigravityKeychainReader {
    func readCredentials() async throws -> AntigravityOAuthCredentials? {
        AntigravityOAuthCredentials(accessToken: "test-access",
                                   expiry: Date().addingTimeInterval(3600),
                                   refreshToken: "test-refresh-token")
    }
}
