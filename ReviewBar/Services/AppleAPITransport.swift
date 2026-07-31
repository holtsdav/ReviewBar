import Foundation

struct AppleAPIResponse: Sendable {
    let data: Data
    let rateLimitRemaining: Int?
}

actor AppleAPITransport {
    static let allowedHost = "api.appstoreconnect.apple.com"

    private let signer: JWTGenerator
    private let session: URLSession

    init(signer: JWTGenerator, session: URLSession? = nil) {
        self.signer = signer
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(
                configuration: configuration,
                delegate: AppleRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func get(_ url: URL) async throws -> AppleAPIResponse {
        try validate(url)
        return try await perform(url, mayRetryAuthentication: true)
    }

    private func perform(_ url: URL, mayRetryAuthentication: Bool) async throws -> AppleAPIResponse {
        try Task.checkCancellation()
        let path = url.path(percentEncoded: true)
        let requestTarget = url.query(percentEncoded: true).map { "\(path)?\($0)" } ?? path
        let token = try await signer.token(forGETPath: requestTarget)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw AppError(kind: .malformedResponse, message: "Apple returned an unexpected network response.")
        }

        if (200..<300).contains(http.statusCode) {
            return AppleAPIResponse(
                data: data,
                rateLimitRemaining: Self.rateLimitRemaining(from: http.value(forHTTPHeaderField: "X-Rate-Limit"))
            )
        }

        switch http.statusCode {
        case 401 where mayRetryAuthentication:
            await signer.invalidate(path: requestTarget)
            return try await perform(url, mayRetryAuthentication: false)
        case 401:
            throw AppleHTTPErrorMapper.map(statusCode: http.statusCode, data: data, retryAfterHeader: nil)
        default:
            throw AppleHTTPErrorMapper.map(
                statusCode: http.statusCode,
                data: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
    }

    private func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == Self.allowedHost,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            throw AppError(kind: .malformedResponse, message: "Apple returned an unsafe pagination link, so ReviewBar stopped loading more data.")
        }
    }

    private static func rateLimitRemaining(from value: String?) -> Int? {
        guard let value else { return nil }
        for part in value.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "user-hour-rem" {
                return Int(pair[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

enum AppleHTTPErrorMapper {
    static func map(statusCode: Int, data: Data, retryAfterHeader: String?) -> AppError {
        let appleCode = (try? JSONDecoder().decode(AppleErrorDocument.self, from: data))?.errors.first?.code
        switch statusCode {
        case 401:
            return AppError(
                kind: .invalidCredentials,
                message: "Apple could not authenticate this key. Check its key type and IDs, or create a replacement if it was revoked."
            )
        case 403:
            return AppError(
                kind: .insufficientPermission,
                message: "Apple denied this request. Check that the key is active and its App Store Connect user can view this app and feature."
            )
        case 429:
            let retryAfter = retryAfterHeader.flatMap(TimeInterval.init)
            return AppError(
                kind: .rateLimited(retryAfter: retryAfter),
                message: retryAfter.map { "Apple asked ReviewBar to wait about \(Int($0)) seconds before refreshing again." }
                    ?? "Apple has temporarily rate limited this key. ReviewBar will keep the cached data available."
            )
        case 500...599:
            return AppError(
                kind: .appleUnavailable,
                message: "App Store Connect is temporarily unavailable. Your cached data is still available."
            )
        default:
            let suffix = appleCode.map { " (Apple code: \($0))" } ?? ""
            return AppError(
                kind: .other,
                message: "Apple rejected the request\(suffix). Your cached data is unchanged."
            )
        }
    }
}

private struct AppleErrorDocument: Decodable {
    struct ErrorItem: Decodable {
        let code: String?
    }
    let errors: [ErrorItem]
}

// This delegate contains no mutable state; the conformance is safe across URLSession delegate queues.
private final class AppleRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let destination = request.url,
              original.scheme?.lowercased() == "https",
              destination.scheme?.lowercased() == "https",
              original.host?.lowercased() == AppleAPITransport.allowedHost,
              destination.host?.lowercased() == AppleAPITransport.allowedHost,
              destination.user == nil,
              destination.password == nil,
              destination.port == nil || destination.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
