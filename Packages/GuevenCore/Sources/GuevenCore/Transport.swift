import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String = "GET"
    public var headers: [String: String] = [:]
    public var body: Data?
    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var code: Int
    public var body: Data
    public var retryAfterSeconds: Int64?
    public var isSuccessful: Bool { (200...299).contains(code) }
    public var text: String { String(decoding: body, as: UTF8.self) }
    public init(code: Int, body: Data = Data(), retryAfterSeconds: Int64? = nil) {
        self.code = code; self.body = body; self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Netzwerkzugriff hinter einem Protokoll, damit Dienste ohne Netz getestet werden können.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Produktiver Transport über `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        let http = response as? HTTPURLResponse
        let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        return HTTPResponse(code: http?.statusCode ?? 0, body: data, retryAfterSeconds: retry)
    }
}
