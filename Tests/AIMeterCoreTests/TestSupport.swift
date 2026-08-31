import Foundation
import ObjectiveC
@testable import AIMeterCore

/// URLProtocol-based network stubbing so provider tests never touch the wire.
///
/// Each test session gets its OWN runtime-created URLProtocol subclass with its
/// own handler registry. Swift Testing runs tests in parallel, and a single
/// global handler would let one test's stub leak into another's in-flight
/// request; per-session subclasses make the stubs race-free by construction.
final class StubURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let data: Data
        let headers: [String: String]

        static func ok(_ data: Data) -> Response {
            Response(status: 200, data: data, headers: [:])
        }
    }

    typealias Handler = (URLRequest) throws -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [ObjectIdentifier: Handler] = [:]
    nonisolated(unsafe) private static var captured: [ObjectIdentifier: [URLRequest]] = [:]

    /// Registers (or clears) the response handler for one session's subclass.
    static func setHandler(_ handler: Handler?, forClass cls: AnyClass) {
        lock.lock(); defer { lock.unlock() }
        handlers[ObjectIdentifier(cls)] = handler
        captured[ObjectIdentifier(cls)] = []
    }

    /// Requests captured by this session's subclass, for header/method asserts.
    static func capturedRequests(forClass cls: AnyClass) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured[ObjectIdentifier(cls)] ?? []
    }

    private static func handler(forClass cls: AnyClass) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[ObjectIdentifier(cls)]
    }

    private static func record(_ request: URLRequest, forClass cls: AnyClass) {
        lock.lock(); defer { lock.unlock() }
        captured[ObjectIdentifier(cls), default: []].append(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool { false }

    override func startLoading() {
        // `self` is an instance of this test's runtime subclass. NB: Swift's
        // `type(of:)` resolves runtime-created ObjC subclasses back to the base
        // class, so key the registry on the raw isa instead.
        let cls = object_getClass(self) ?? StubURLProtocol.self
        Self.record(request, forClass: cls)
        let response: Response
        do {
            response = try Self.handler(forClass: cls)?(request) ?? Response(status: 599, data: Data(), headers: [:])
        } catch {
            response = Response(status: 599, data: Data("stub handler threw: \(error)".utf8), headers: [:])
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                   httpVersion: nil, headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum StubProtocolFactory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0

    /// Allocates a fresh URLProtocol subclass at runtime. Each call yields a
    /// distinct ObjC class, so its handler registry is isolated per session.
    static func makeFreshClass() -> StubURLProtocol.Type {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let name = "AIMeterStubURLProtocol_\(counter)"
        guard let cls = objc_allocateClassPair(StubURLProtocol.self, name, 0) else {
            fatalError("could not allocate stub URLProtocol subclass")
        }
        objc_registerClassPair(cls)
        return cls as! StubURLProtocol.Type
    }
}

/// A URLSession bound to one unique stub protocol class: register responses
/// with `respond(_:)` and assert on captured requests with `requests()`.
struct StubSession {
    let session: URLSession
    let protocolClass: StubURLProtocol.Type

    init() {
        let cls = StubProtocolFactory.makeFreshClass()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [cls]
        self.protocolClass = cls
        self.session = URLSession(configuration: configuration)
    }

    func respond(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.setHandler(handler, forClass: protocolClass)
    }

    func requests() -> [URLRequest] {
        StubURLProtocol.capturedRequests(forClass: protocolClass)
    }
}

extension URLRequest {
    /// Reads the request body either from `httpBody` or by draining
    /// `httpBodyStream` — URLSession converts `httpBody` to a stream before
    /// the URLProtocol handler sees the request.
    var aimeterBodyText: String? {
        if let body = httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}

enum Fixtures {
    static func load(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        guard let url else { fatalError("fixture \(name).json missing") }
        return try Data(contentsOf: url)
    }
}

/// Deterministic token source for provider tests.
struct StubClaudeTokenSource: ClaudeTokenSource {
    let token: String
    func accessToken() async throws -> String { token }
}

/// Token refresher stub that records calls and returns canned tokens.
final class StubTokenRefresher: TokenRefresher, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private(set) var calls: [String] = []
    var result: Result<RefreshedToken, Error>

    init(result: Result<RefreshedToken, Error>) {
        self.result = result
    }

    func refresh(refreshToken: String) async throws -> RefreshedToken {
        record(refreshToken)
        switch result {
        case .success(let token): return token
        case .failure(let error): throw error
        }
    }

    private func record(_ refreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(refreshToken)
    }
}