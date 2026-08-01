import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

@Suite(.serialized)
struct AnalyticsProviderTests {
    @Test("A one-time snapshot follows the official chain, paginates segments, and imports gzip TSV")
    func snapshotImportAndInstanceCache() async throws {
        AnalyticsAPIURLProtocol.configure(.success)
        let provider = try makeProvider()

        let first = try await provider.fetchAnalytics(appID: "app")
        guard case .dataset(let dataset) = first else {
            Issue.record("Expected an Analytics dataset")
            return
        }
        #expect(dataset.accessType == "ONE_TIME_SNAPSHOT")
        #expect(dataset.summary(range: .sevenDays).totalDownloads == .value(5))
        #expect(AnalyticsAPIURLProtocol.downloadCount == 2)

        _ = try await provider.fetchAnalytics(appID: "app")
        #expect(AnalyticsAPIURLProtocol.downloadCount == 2)
        #expect(AnalyticsAPIURLProtocol.requestedPaths.contains("/v1/analyticsReportInstances/instance/segments"))
    }

    @Test("A downstream Analytics 403 propagates as a permission failure")
    func downstreamPermission() async throws {
        AnalyticsAPIURLProtocol.configure(.downstream403)
        let provider = try makeProvider()
        do {
            _ = try await provider.fetchAnalytics(appID: "app")
            Issue.record("Expected permission failure")
        } catch let error as AppError {
            #expect(error.kind == .insufficientPermission)
        }
    }

    @Test("A downstream Analytics 429 propagates rate-limit context")
    func downstreamRateLimit() async throws {
        AnalyticsAPIURLProtocol.configure(.downstream429)
        let provider = try makeProvider()
        do {
            _ = try await provider.fetchAnalytics(appID: "app")
            Issue.record("Expected rate limiting")
        } catch let error as AppError {
            #expect(error.kind == .rateLimited(retryAfter: 42))
        }
    }

    private func makeProvider() throws -> AppStoreConnectAnalyticsProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsAPIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            scope: .individual
        )
        return AppStoreConnectAnalyticsProvider(
            transport: AppleAPITransport(signer: try JWTGenerator(credential: credential), session: session),
            downloader: AnalyticsSegmentDownloader(session: session),
            baseURL: try #require(URL(string: "https://api.appstoreconnect.apple.com/v1")),
            instanceCache: MemoryAnalyticsInstanceCache()
        )
    }
}

private final class AnalyticsAPIURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case success, downstream403, downstream429 }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .success
    nonisolated(unsafe) private static var downloads = 0
    nonisolated(unsafe) private static var paths: [String] = []

    static var downloadCount: Int { lock.withLock { downloads } }
    static var requestedPaths: [String] { lock.withLock { paths } }

    static func configure(_ newMode: Mode) {
        lock.withLock {
            mode = newMode
            downloads = 0
            paths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mode = Self.lock.withLock { () -> Mode in
            Self.paths.append(url.path)
            if url.host == "download.example" { Self.downloads += 1 }
            return Self.mode
        }

        let status: Int
        let headers: [String: String]
        let data: Data
        if url.host == "download.example" {
            status = 200
            headers = ["Content-Type": "application/gzip"]
            data = segmentData(id: url.lastPathComponent)
        } else if url.path.hasSuffix("/instances"), mode != .success {
            status = mode == .downstream403 ? 403 : 429
            headers = mode == .downstream429
                ? ["Content-Type": "application/json", "Retry-After": "42"]
                : ["Content-Type": "application/json"]
            data = Data(#"{"errors":[{"code":"FORBIDDEN"}]}"#.utf8)
        } else {
            status = 200
            headers = ["Content-Type": "application/json"]
            data = responseData(for: url)
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func responseData(for url: URL) -> Data {
        switch url.path {
        case "/v1/apps/app/analyticsReportRequests":
            return json(#"{"data":[{"type":"analyticsReportRequests","id":"snapshot","attributes":{"accessType":"ONE_TIME_SNAPSHOT","stoppedDueToInactivity":false}}],"links":{}}"#)
        case "/v1/analyticsReportRequests/snapshot/reports":
            return json(#"{"data":[{"type":"analyticsReports","id":"downloads","attributes":{"name":"App Store Downloads Standard","category":"COMMERCE"}}],"links":{}}"#)
        case "/v1/analyticsReports/downloads/instances":
            return json(#"{"data":[{"type":"analyticsReportInstances","id":"instance","attributes":{"granularity":"DAILY","processingDate":"2026-08-01"}}],"links":{}}"#)
        case "/v1/analyticsReportInstances/instance/segments":
            return segmentPage()
        default:
            return json(#"{"data":[],"links":{}}"#)
        }
    }

    private func segmentPage() -> Data {
        let first = segmentData(id: "segment-1")
        let second = segmentData(id: "segment-2")
        let payload: [String: Any] = [
            "data": [
                segmentResource(id: "segment-1", data: first),
                segmentResource(id: "segment-2", data: second)
            ],
            "links": [:]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private func segmentResource(id: String, data: Data) -> [String: Any] {
        [
            "type": "analyticsReportSegments",
            "id": id,
            "attributes": [
                "checksum": Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "sizeInBytes": data.count,
                "url": "https://download.example/\(id)"
            ]
        ]
    }

    private func segmentData(id: String) -> Data {
        let encoded = id == "segment-1"
            ? "H4sIAAAAAAAAA3NJLEnldMkvz8vJT0xRCKksSOV0zi/NKynmMjIwMtM1MNc1NuR0yywqLtENycxNVYAp5TTiAgALC2VDOwAAAA=="
            : "H4sIAAAAAAAAA3NJLEnldMkvz8vJT0xRCKksSOV0zi/NKynmMjIwMtM1MNc1NuQMSk2BquA05gIAUxAh9DIAAAA="
        return Data(base64Encoded: encoded) ?? Data()
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }
}
