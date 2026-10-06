import Foundation
import Security

/// Antigravity exposes two shared quota pools (Gemini Models; Claude + GPT
/// models), each with a rolling 5-hour and a weekly window. Source order per
/// research (docs/research/provider-data-sources-gemini-antigravity-opencode.md):
///   1. local language server (app/IDE running) — ps + lsof → Connect-RPC
///   2. `agy` CLI warm PTY session — v1.5; protocol hook only, not implemented
///   3. remote OAuth — keychain `gemini`/`antigravity` → daily-cloudcode-pa
///
/// Never write back to Antigravity's keychain item or token file. Refreshed
/// tokens are cached in memory only.

// MARK: - Discovery (path 1)

/// A local Antigravity language-server endpoint discovered on this machine.
public struct AntigravityLanguageServer: Sendable, Equatable {
    public let port: Int
    public let csrfToken: String?
    public init(port: Int, csrfToken: String?) {
        self.port = port
        self.csrfToken = csrfToken
    }
}

/// Finds the running Antigravity language server (injectable for tests).
public protocol AntigravityLanguageServerProbe: Sendable {
    func locateLanguageServer() async -> AntigravityLanguageServer?
}

/// Real implementation: `ps` for `language_server --app_data_dir antigravity`
/// (or antigravity-ide / antigravity-cli / agy), then `lsof` for the listening
/// port; CSRF token comes from the process flags. Any failure degrades to nil.
public struct ProcessAntigravityLanguageServerProbe: AntigravityLanguageServerProbe {
    public init() {}

    public func locateLanguageServer() async -> AntigravityLanguageServer? {
        // Blocking subprocess calls run detached so the caller never blocks.
        await Task.detached(priority: .utility) { Self.locateBlocking() }.value
    }

    fileprivate static func locateBlocking() -> AntigravityLanguageServer? {
        guard let ps = runProcess("/bin/ps", ["-ax", "-o", "pid=,command="]) else { return nil }
        for line in ps.split(separator: "\n") {
            let command = String(line)
            guard command.contains("language_server"),
                  ["antigravity", "antigravity-ide", "antigravity-cli", "agy"].contains(where: { command.contains($0) })
            else { continue }

            let pid = command.split(separator: " ").first.flatMap { Int($0) }
            let csrf = extractFlag(command, ["--csrf_token", "--extension_server_csrf_token"])
            var port = extractFlag(command, ["--extension_server_port"]).flatMap(Int.init)

            if let pid, let lsof = runProcess("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)]) {
                // Prefer the highest listening port (the quota service binds
                // its own port distinct from the extension port).
                let ports = self.listenPorts(in: lsof)
                if let highest = ports.max() { port = highest }
            }
            if let port, port > 0 {
                return AntigravityLanguageServer(port: port, csrfToken: csrf)
            }
            // A matching process without a discoverable port → treat as absent.
        }
        return nil
    }

    private static func extractFlag(_ command: String, _ flags: [String]) -> String? {
        for flag in flags {
            if let range = command.range(of: flag) {
                let tail = command[range.upperBound...].drop(while: { $0 == " " || $0 == "=" })
                let token = tail.prefix(while: { !$0.isWhitespace })
                if !token.isEmpty { return String(token) }
            }
        }
        return nil
    }

    private static func listenPorts(in lsofOutput: String) -> [Int] {
        lsofOutput.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard text.contains("(LISTEN)") else { return nil }
            // Lines look like: ... TCP 127.0.0.1:57755 (LISTEN) — capture the port.
            let pattern = #"(TCP |\*:)([0-9]{2,5}) \(LISTEN\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let portRange = Range(match.range(at: 2), in: text)
            else { return nil }
            let portString = String(text[portRange])
            // Strip any trailing IPv6 zone or whitespace.
            let digits = portString.prefix(while: { $0.isNumber })
            return Int(String(digits))
        }
    }

    private static func runProcess(_ executable: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        // Never hold a pipe for stderr: drain stdout BEFORE waitUntilExit —
        // waiting first deadlocks once the child fills the 64KB pipe buffer
        // (`ps -ax` output routinely exceeds it on busy machines).
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}

// MARK: - Remote OAuth (path 3)

// ⚠️ Future provider note (Gemini CLI): Google stopped serving Gemini CLI OAuth
// for consumer accounts on 2026-06-18. A future GeminiCliProvider must detect
// the UNSUPPORTED_CLIENT / 403 SUBSCRIPTION_REQUIRED sentinels from
// :loadCodeAssist and hand off to this Antigravity path.

/// Antigravity's stored OAuth credential (from the `gemini`/`antigravity`
/// keychain item or the legacy read-only token file).
public struct AntigravityOAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiry: Date?
    public var refreshToken: String?
    public init(accessToken: String, expiry: Date?, refreshToken: String?) {
        self.accessToken = accessToken
        self.expiry = expiry
        self.refreshToken = refreshToken
    }
}

/// Reads Antigravity's own stored credential (injectable for tests).
public protocol AntigravityKeychainReader: Sendable {
    /// Returns nil when no credential exists; throws on malformed/denied reads.
    func readCredentials() async throws -> AntigravityOAuthCredentials?
}

/// Real implementation: the `gemini` / `antigravity` generic-password item
/// (`security find-generic-password -a antigravity -s gemini -w`), which may
/// be `go-keyring-base64:`-prefixed, then the legacy read-only token file.
public struct KeychainAntigravityKeychainReader: AntigravityKeychainReader {
    public static let service = "gemini"
    public static let account = "antigravity"

    public var legacyTokenPath: URL

    public init(legacyTokenPath: URL? = nil) {
        self.legacyTokenPath = legacyTokenPath
            ?? URL(fileURLWithPath: NSString(string: "~/.gemini/antigravity-cli/antigravity-oauth-token").expandingTildeInPath)
    }

    public func readCredentials() async throws -> AntigravityOAuthCredentials? {
        if let data = keychainData() {
            if let creds = Self.parse(data) { return creds }
            throw ProviderError.unavailable("malformed Antigravity keychain item")
        }
        // Legacy token file from older CLI versions (read-only — never write).
        if FileManager.default.fileExists(atPath: legacyTokenPath.path),
           let data = try? Data(contentsOf: legacyTokenPath),
           let creds = Self.parse(data) {
            return creds
        }
        return nil
    }

    private func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            return out as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // ACL prompt denied or keychain locked → degrade to unauthorized.
            return nil
        default:
            return nil
        }
    }

    /// Parses `{"token": {"access_token": …, "expiry": "<RFC3339>", "refresh_token": …}}`
    /// with the optional `go-keyring-base64:` wrapper.
    static func parse(_ data: Data) -> AntigravityOAuthCredentials? {
        var bytes = data
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("go-keyring-base64:") {
            let b64 = text.dropFirst("go-keyring-base64:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: String(b64)) else { return nil }
            bytes = decoded
        }
        guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let token = json["token"] as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty
        else { return nil }
        return AntigravityOAuthCredentials(
            accessToken: access,
            expiry: (token["expiry"] as? String).flatMap { ISO8601Dates.parse($0) },
            refreshToken: token["refresh_token"] as? String
        )
    }
}

/// Refreshes an Antigravity OAuth token with externally supplied client credentials.
public protocol AntigravityOAuthRefresher: Sendable {
    func refresh(refreshToken: String) async throws -> RefreshedToken
}

public struct GoogleAntigravityOAuthRefresher: AntigravityOAuthRefresher {
    private let session: URLSession
    private let client: AntigravityOAuthClient?

    public init(session: URLSession = .shared,
                client: AntigravityOAuthClient? = .fromEnvironment()) {
        self.session = session
        self.client = client
    }

    public func refresh(refreshToken: String) async throws -> RefreshedToken {
        guard let client else {
            throw ProviderError.unauthorized(detail: "Antigravity OAuth refresh client is not configured. Set AIMETER_ANTIGRAVITY_CLIENT_ID and AIMETER_ANTIGRAVITY_CLIENT_SECRET locally.")
        }
        var request = URLRequest(url: AntigravityProvider.oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "client_secret", value: client.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let response = try await HTTPOps.send(request, session: session)
        let data = try response.validated()
        struct RefreshResponse: Decodable {
            let accessToken: String?
            let expiresIn: Double?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        do {
            let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
            guard let access = decoded.accessToken, !access.isEmpty else {
                throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
            }
            let now = Date()
            let expiresAt = decoded.expiresIn.map { now.addingTimeInterval($0) }
            return RefreshedToken(accessToken: access, refreshToken: nil,
                                  issuedAt: now, expiresAt: expiresAt)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unavailable("unexpected Antigravity refresh payload")
        }
    }
}

// MARK: - Quota summary

/// Connect-RPC `RetrieveUserQuotaSummary` response. Groups are the shared
/// pools (e.g. "Gemini models", "Claude and GPT models"); buckets are the
/// 5-hour and weekly windows. Tolerates groups at the root or under
/// `response` / `summary` wrappers.
public struct AntigravityQuotaSummary: Decodable, Equatable, Sendable {
    public struct Group: Decodable, Equatable, Sendable {
        public let displayName: String?
        public let buckets: [Bucket]?
        public let disabled: Bool?
    }
    public struct Bucket: Decodable, Equatable, Sendable {
        public let bucketId: String?
        public let displayName: String?
        /// Live API (verified 2026-08-31) puts `remainingFraction` DIRECTLY on
        /// the bucket (`{bucketId, displayName, window, remainingFraction,
        /// resetTime, description}`); the older doc shape nests it under
        /// `remaining`. Both decode; the flat value wins.
        public let remainingFraction: Double?
        public let remaining: Remaining?
        /// Window kind tag used live (`"5h"` / `"week"`).
        public let window: String?
        public let resetTime: Date?
        public let disabled: Bool?

        enum CodingKeys: String, CodingKey {
            case bucketId, displayName, remainingFraction, remaining, window, resetTime, disabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bucketId = try c.decodeIfPresent(String.self, forKey: .bucketId)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            // Flat first, nested fallback.
            if let flat = try c.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                remainingFraction = flat
            } else if let nested = try c.decodeIfPresent(Remaining.self, forKey: .remaining) {
                remainingFraction = nested.remainingFraction
            } else {
                remainingFraction = nil
            }
            remaining = try c.decodeIfPresent(Remaining.self, forKey: .remaining)
            window = try c.decodeIfPresent(String.self, forKey: .window)
            resetTime = try c.decodeIfPresent(Date.self, forKey: .resetTime)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
        }
    }
    public struct Remaining: Decodable, Equatable, Sendable {
        public let remainingFraction: Double?
    }

    public let groups: [Group]?
    public let planName: String?
    public let accountEmail: String?

    enum CodingKeys: String, CodingKey {
        case groups, planName, accountEmail, response, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedGroups = try c.decodeIfPresent([Group].self, forKey: .groups)
        for wrapper in [CodingKeys.response, CodingKeys.summary] where decodedGroups == nil {
            if let nested = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: wrapper) {
                decodedGroups = try nested.decodeIfPresent([Group].self, forKey: .groups)
            }
        }
        groups = decodedGroups
        planName = try c.decodeIfPresent(String.self, forKey: .planName)
        accountEmail = try c.decodeIfPresent(String.self, forKey: .accountEmail)
    }
}

// MARK: - Provider

/// Antigravity quota: local language server first, remote OAuth fallback.
/// The `agy` CLI warm-PTY path is a v1.5 hook — not implemented.
public final class AntigravityProvider: AIProvider, @unchecked Sendable {
    public static let summaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    public static let remoteQuotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    /// Fallback for the same quota summary on the non-daily host, and a
    /// `loadCodeAssist` shaped fallback is handled inside `quotaFromRemote`
    /// (both keep the pi refresh → quota ordering the spec requires).
    public static let fallbackQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    public static let oauthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let userAgent = "antigravity/1.11.3 \(AntigravitySystem.osName)/\(AntigravitySystem.archName)"

    public let id = ProviderID("antigravity")
    public let displayName = "Antigravity"

    private actor TokenCache {
        private var token: RefreshedToken?
        func current() -> RefreshedToken? { token }
        func store(_ refreshed: RefreshedToken) { token = refreshed }
        func isFresh() -> Bool {
            guard let t = token else { return false }
            if let exp = t.expiresAt { return exp > Date().addingTimeInterval(60) }
            // No expiry → treat as fresh for 55 minutes after issue.
            return Date().timeIntervalSince(t.issuedAt) < 3300
        }
    }

    /// Bounds a step (e.g. the local language-server probe) with a hard
    /// deadline so a stalled 127.0.0.1 service can't hang the HUD refresh on
    /// URLSession's 60s default. The loser task is cancelled.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                               _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProviderError.unavailable("Antigravity step timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private let session: URLSession
    private let localSession: URLSession
    private let probe: any AntigravityLanguageServerProbe
    private let keychainReader: any AntigravityKeychainReader
    private let piAuth: (any PiAuthReading)?
    private let refresher: any AntigravityOAuthRefresher
    private let tokenCache = TokenCache()

    public init(session: URLSession = .shared,
                localSession: URLSession? = nil,
                probe: any AntigravityLanguageServerProbe = ProcessAntigravityLanguageServerProbe(),
                keychainReader: any AntigravityKeychainReader = KeychainAntigravityKeychainReader(),
                piAuth: (any PiAuthReading)? = nil,
                refresher: any AntigravityOAuthRefresher = GoogleAntigravityOAuthRefresher()) {
        self.session = session
        self.localSession = localSession ?? AntigravityLocalhostSession.make()
        self.probe = probe
        self.keychainReader = keychainReader
        self.piAuth = piAuth
        self.refresher = refresher
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        // Path 1: local language server while the app is running (richest).
        // Bounded: a stalled 127.0.0.1 service must not hang the poll — on
        // timeout we fall through to the remote OAuth path.
        if let ls = await probe.locateLanguageServer() {
            do {
                let summary = try await Self.withTimeout(8) {
                    try await self.quotaFromLanguageServer(ls)
                }
                return Self.snapshot(from: summary, planName: summary.planName, fetchedAt: Date())
            } catch {
                // Local service is up but the call failed/timed out → fall
                // through to the remote OAuth path (degrades gracefully).
            }
        }
        // Path 3: remote OAuth with Antigravity's stored credential.
        // Pi auto-refresh happens inside remoteAccessToken before the quota
        // call; on 401 we attempt one reactive refresh then surface a clear
        // "Auth expired → Reconnect in Settings" so Settings shows why the
        // HUD row is hidden rather than silently disappearing.
        let accessToken = try await remoteAccessToken()
        do {
            let summary = try await quotaFromRemote(accessToken: accessToken)
            return Self.snapshot(from: summary, planName: nil, fetchedAt: Date())
        } catch let error as ProviderError {
            switch error {
            case .unauthorized:
                // Reactive refresh: token looked fresh but server says 401.
                // Try one refresh using the stored refresh token, then retry.
                if let refreshed = try? await refreshForRetry(),
                   let retry = try? await quotaFromRemote(accessToken: refreshed) {
                    return Self.snapshot(from: retry, planName: nil, fetchedAt: Date())
                }
                throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
            default:
                throw error
            }
        }
    }

    private func remoteAccessToken() async throws -> String {
        // Cached refreshed token is in-memory and never written to ~/.pi.
        if await tokenCache.isFresh(), let cached = await tokenCache.current() {
            return cached.accessToken
        }
        // Credential source order: Pi's stored OAuth (auto-connect when the
        // app/CLI is closed) → keychain live-read (Decision 3).
        // Pi path auto-refreshes via https://oauth2.googleapis.com/token with
        // locally configured client credentials when expiry ≤ now+60s, updating
        // access/expiry in-memory only.
        var credentials: AntigravityOAuthCredentials?
        if let piAuth {
            // Pi auto-refresh lives in PiAntigravityTokenSource as required
            // by the spec — it checks expiry ≤ now+60s, calls
            // https://oauth2.googleapis.com/token with the configured client,
            // and caches the new access/expiry in-memory (never writes to
            // ~/.pi). On refresh failure it throws the reconnect message.
            let piSource = PiAntigravityTokenSource(auth: piAuth, refresher: refresher)
            do {
                if let refreshed = try await piSource.refreshedCredentials() {
                    if let exp = refreshed.expiry, refreshed.accessToken != piAuth.accessToken(for: PiAntigravityTokenSource.providerID) {
                        let cachedToken = RefreshedToken(accessToken: refreshed.accessToken,
                                                          refreshToken: refreshed.refreshToken,
                                                          issuedAt: Date(),
                                                          expiresAt: exp)
                        await tokenCache.store(cachedToken)
                    }
                    credentials = refreshed
                }
            } catch let err as ProviderError {
                throw err
            } catch {
                throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
            }
            if credentials == nil {
                credentials = PiAntigravityTokenSource(auth: piAuth).credentials
            }
        }
        if credentials == nil {
            credentials = try await keychainReader.readCredentials()
        }
        guard let credentials else {
            throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
        }
        // Proactive refresh for keychain-sourced credentials (or Pi credentials
        // when the Pi source was constructed without a refresher).
        if let expiry = credentials.expiry,
           expiry <= Date().addingTimeInterval(60),
           let refresh = credentials.refreshToken {
            do {
                let refreshed = try await refresher.refresh(refreshToken: refresh)
                await tokenCache.store(refreshed)
                return refreshed.accessToken
            } catch {
                throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
            }
        }
        return credentials.accessToken
    }

    /// One reactive refresh attempt for the 401 retry path — uses the stored
    /// refresh token from Pi or keychain, stores the new access token
    /// in-memory, and returns it for the retry.
    private func refreshForRetry() async throws -> String {
        var refreshToken: String?
        if let piAuth,
           let t = PiAntigravityTokenSource(auth: piAuth).credentials?.refreshToken {
            refreshToken = t
        }
        if refreshToken == nil {
            refreshToken = try await keychainReader.readCredentials()?.refreshToken
        }
        guard let refresh = refreshToken, !refresh.isEmpty else {
            throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
        }
        let refreshed = try await refresher.refresh(refreshToken: refresh)
        await tokenCache.store(refreshed)
        return refreshed.accessToken
    }

    private func quotaFromLanguageServer(_ ls: AntigravityLanguageServer) async throws -> AntigravityQuotaSummary {
        guard let url = URL(string: "https://127.0.0.1:\(ls.port)\(Self.summaryPath)") else {
            throw ProviderError.unavailable("bad Antigravity local port")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let csrf = ls.csrfToken, !csrf.isEmpty {
            request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.httpBody = Data(#"{"ideName":"antigravity","extensionName":"antigravity","locale":"en","ideVersion":"unknown"}"#.utf8)
        return try await sendQuotaRequest(request, session: localSession)
    }

    private func quotaFromRemote(accessToken: String) async throws -> AntigravityQuotaSummary {
        // Primary: daily-cloudcode-pa retrieveUserQuotaSummary with UA
        // Fallback: cloudcode-pa same path (or loadCodeAssist-shaped fallback
        // — the “or loadCodeAssist” in the spec is covered here by trying the
        // alternate host before giving up; both keep pi refresh → quota order).
        let urls = [Self.remoteQuotaURL, Self.fallbackQuotaURL]
        var lastError: Error?
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = Data("{}".utf8)
            do {
                return try await sendQuotaRequest(request, session: session)
            } catch let error as ProviderError {
                // 401 is auth — don't silently fall back, let fetchUsage map
                // it to "Auth expired → Reconnect in Settings".
                if case .unauthorized = error { throw error }
                lastError = error
                continue
            } catch {
                lastError = error
                continue
            }
        }
        if let err = lastError as? ProviderError { throw err }
        throw lastError ?? ProviderError.unavailable("unexpected Antigravity quota payload")
    }

    private func sendQuotaRequest(_ request: URLRequest, session: URLSession) async throws -> AntigravityQuotaSummary {
        let response = try await HTTPOps.send(request, session: session)
        let data = try response.validated()
        do {
            return try JSONDecoder.flexibleISO8601.decode(AntigravityQuotaSummary.self, from: data)
        } catch {
            throw ProviderError.unavailable("unexpected Antigravity quota payload")
        }
    }

    /// Maps the two pools onto windows: 5h/"session" buckets → session5h,
    /// "week" buckets → week7d, labeled by pool; used = (1 − remainingFraction).
    static func snapshot(from summary: AntigravityQuotaSummary, planName: String?, fetchedAt: Date) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for group in summary.groups ?? [] where group.disabled != true {
            for bucket in group.buckets ?? [] where bucket.disabled != true {
                guard let fraction = bucket.remainingFraction else { continue }
                let used = Self.clampedPercent((1 - fraction) * 100)
                let id = (bucket.bucketId ?? "").lowercased()
                let name = (bucket.displayName ?? "").lowercased()
                let tag = (bucket.window ?? "").lowercased()
                let kind: WindowKind
                if id.contains("5h") || name.contains("5h") || name.contains("session") || tag.contains("5h") {
                    kind = .session5h
                } else if id.contains("week") || name.contains("week") || tag.contains("week") {
                    kind = .week7d
                } else {
                    kind = .week7d // unknown bucket labels default to weekly
                }
                windows.append(UsageWindow(kind: kind, usedPercent: used,
                                           resetsAt: bucket.resetTime, label: group.displayName))
            }
        }
        return UsageSnapshot(planName: planName, windows: windows, fetchedAt: fetchedAt)
    }

    static func clampedPercent(_ fraction: Double) -> Int {
        min(100, max(0, Int(fraction.rounded())))
    }
}

enum AntigravitySystem {
    static var osName: String { "Darwin" }
    static var archName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// Self-signed TLS is allowed ONLY for the localhost loopback used by the
/// Antigravity language server; every other host falls back to default handling.
final class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let trustedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        let space = challenge.protectionSpace
        if trustedHosts.contains(space.host),
           space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum AntigravityLocalhostSession {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
    }
}