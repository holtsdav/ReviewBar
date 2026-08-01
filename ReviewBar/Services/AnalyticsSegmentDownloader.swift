import CryptoKit
import Foundation

enum AnalyticsSegmentDownloadError: Error {
    case expiredURL
}

actor AnalyticsSegmentDownloader {
    private let session: URLSession
    private let maximumCompressedBytes = 64 * 1_024 * 1_024

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(
                configuration: configuration,
                delegate: AnalyticsDownloadRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func download(_ segment: AnalyticsReportSegmentAPIResource) async throws -> Data {
        guard let attributes = segment.attributes,
              let url = attributes.url,
              let expectedSize = attributes.sizeInBytes,
              expectedSize >= 0,
              expectedSize <= maximumCompressedBytes,
              let checksum = attributes.checksum?.lowercased(), checksum.count == 32 else {
            throw AppError(kind: .malformedResponse, message: "Apple returned incomplete Analytics segment metadata.")
        }
        try validate(url)
        var request = URLRequest(url: url)
        request.setValue("application/gzip,application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw AppError(kind: .malformedResponse, message: "Apple returned an unexpected Analytics download response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AnalyticsSegmentDownloadError.expiredURL }
        guard (200..<300).contains(http.statusCode),
              data.count == expectedSize,
              data.count <= maximumCompressedBytes else {
            throw AppError(kind: .malformedResponse, message: "An Analytics segment was incomplete or exceeded its declared size.")
        }
        let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == checksum else {
            throw AppError(kind: .malformedResponse, message: "An Analytics segment failed Apple's checksum verification.")
        }
        return data
    }

    private func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw AppError(kind: .malformedResponse, message: "Apple returned an unsafe Analytics download URL.")
        }
    }
}

private final class AnalyticsDownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
