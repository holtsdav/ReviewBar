import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

@Suite(.serialized)
struct NetworkingTests {
    @Test("HTTP errors map to distinct user-facing categories", arguments: [
        (401, AppError.Kind.invalidCredentials),
        (403, AppError.Kind.insufficientPermission),
        (429, AppError.Kind.rateLimited(retryAfter: 30)),
        (503, AppError.Kind.appleUnavailable)
    ])
    func errorMapping(status: Int, expectedKind: AppError.Kind) {
        let data = Data(#"{"errors":[{"code":"RATE_LIMIT_EXCEEDED"}]}"#.utf8)
        let mapped = AppleHTTPErrorMapper.map(
            statusCode: status,
            data: data,
            retryAfterHeader: status == 429 ? "30" : nil
        )
        #expect(mapped.kind == expectedKind)
    }

    @Test("Transport rejects hostile pagination hosts before creating a request")
    func hostilePaginationHost() async throws {
        let key = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: key.pemRepresentation,
            scope: .individual
        )
        let transport = AppleAPITransport(signer: try JWTGenerator(credential: credential))
        let url = try #require(URL(string: "https://attacker.example/v1/apps?cursor=stolen"))

        do {
            _ = try await transport.get(url)
            Issue.record("Expected the hostile host to be rejected")
        } catch let error as AppError {
            #expect(error.kind == .malformedResponse)
        }
    }

    @Test("Repository pagination deduplicates IDs, saves the page, and keeps history read")
    func pagination() async throws {
        let dashboard = DemoFixtures.dashboards[0]
        let provider = PaginationTestProvider(dashboard: dashboard)
        let cache = MemorySnapshotCache()
        let reads = ReviewReadStore()
        let repository = DashboardRepository(
            provider: provider,
            cache: cache,
            historyStore: ReleaseHistoryStore(),
            readStore: reads
        )

        let first = try await repository.refresh()
        #expect(first.dashboards[0].reviews.count == dashboard.reviews.count)
        let updated = try await repository.loadMoreReviews(for: dashboard.id, in: first)
        #expect(updated.dashboards[0].reviews.count == dashboard.reviews.count + 1)
        #expect(Set(updated.dashboards[0].reviews.map(\.id)).count == updated.dashboards[0].reviews.count)
        #expect(await reads.unreadCount(in: updated.dashboards[0].reviews) == 0)
        #expect(await cache.load() == updated)
    }

    @Test("A partial endpoint failure preserves that section from cache")
    func partialFailurePreservesCache() async throws {
        let saved = DemoFixtures.dashboards[0]
        let failedDashboard = AppDashboard(
            app: saved.app,
            releases: [],
            reviews: [],
            builds: [],
            nextReviewsPage: nil,
            fetchedAt: .now,
            sectionIssues: [
                .releases: SectionIssue(error: AppError(kind: .insufficientPermission, message: "No release access")),
                .reviews: SectionIssue(error: AppError(kind: .offline, message: "Offline")),
                .builds: SectionIssue(error: AppError(kind: .appleUnavailable, message: "Unavailable"))
            ]
        )
        let cache = MemorySnapshotCache(collection: DashboardCollection(
            dashboards: [saved],
            fetchedAt: DemoFixtures.referenceDate
        ))
        let repository = DashboardRepository(
            provider: PaginationTestProvider(dashboard: failedDashboard),
            cache: cache,
            historyStore: ReleaseHistoryStore(),
            readStore: ReviewReadStore()
        )

        let refreshed = try await repository.refresh().dashboards[0]
        #expect(refreshed.releases == saved.releases)
        #expect(refreshed.reviews == saved.reviews)
        #expect(refreshed.builds == saved.builds)
        #expect(refreshed.sectionIssues.count == 3)
        #expect(refreshed.sectionIssues.values.allSatisfy { $0.usingCachedData == true })
        #expect(refreshed.sectionIssues.values.allSatisfy { $0.cachedAt == saved.fetchedAt })
        let collection = try await repository.cached()
        #expect(collection?.fetchedAt == DemoFixtures.referenceDate)
        #expect(collection?.hasStaleSections == true)
        let secondRefresh = try await repository.refresh().dashboards[0]
        #expect(secondRefresh.sectionIssues.values.allSatisfy { $0.cachedAt == saved.fetchedAt })
    }

    @Test("Canceled refresh never persists a partial collection")
    func cancellationDoesNotSave() async throws {
        let cache = MemorySnapshotCache()
        let repository = DashboardRepository(
            provider: SlowCancellationProvider(),
            cache: cache,
            historyStore: ReleaseHistoryStore(),
            readStore: ReviewReadStore()
        )
        let task = Task { try await repository.refresh() }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await cache.load() == nil)
    }

    @Test("Apple app pagination follows next links and deduplicates resources")
    func providerPagination() async throws {
        let provider = try makeHTTPProvider(mode: .pages)
        let apps = try await provider.fetchApps()
        #expect(apps.map(\.id) == ["app-1", "app-2"])
        #expect(PagingURLProtocol.requestCount == 2)
        let firstURL = try #require(PagingURLProtocol.requestedURLs.first)
        let queryItems = URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(queryItems?.contains(URLQueryItem(name: "filter[appStoreVersions.platform]", value: "IOS")) == true)
    }

    @Test("Repeating Apple pagination link is rejected")
    func repeatingPagination() async throws {
        let provider = try makeHTTPProvider(mode: .repeating)
        do {
            _ = try await provider.fetchApps()
            Issue.record("Expected a repeating pagination error")
        } catch let error as AppError {
            #expect(error.kind == .malformedResponse)
        }
    }

    @Test("Malformed Apple JSON maps to a specific response error")
    func malformedResponse() async throws {
        let provider = try makeHTTPProvider(mode: .malformed)
        do {
            _ = try await provider.fetchApps()
            Issue.record("Expected decoding to fail")
        } catch {
            #expect(AppError.map(error).kind == .malformedResponse)
        }
    }

    @Test("Transport retries authentication exactly once after a 401")
    func authenticationRetry() async throws {
        let provider = try makeHTTPProvider(mode: .authenticationRetry)
        let apps = try await provider.fetchApps()
        #expect(apps.map(\.id) == ["app-1"])
        #expect(PagingURLProtocol.requestCount == 2)
    }

    private func makeHTTPProvider(mode: PagingURLProtocol.Mode) throws -> AppStoreConnectDataProvider {
        PagingURLProtocol.configure(mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            scope: .individual
        )
        let transport = AppleAPITransport(
            signer: try JWTGenerator(credential: credential),
            session: session
        )
        return AppStoreConnectDataProvider(
            transport: transport,
            baseURL: URL(string: "https://api.appstoreconnect.apple.com/v1")!
        )
    }
}

private actor PaginationTestProvider: DashboardDataProviding {
    private let dashboard: AppDashboard

    init(dashboard: AppDashboard) {
        self.dashboard = dashboard
    }

    func fetchApps() -> [DeveloperApp] {
        [dashboard.app]
    }

    func fetchDashboard(for app: DeveloperApp) -> AppDashboard {
        dashboard
    }

    func fetchReviewsPage(at url: URL) -> ReviewPage {
        ReviewPage(
            reviews: [dashboard.reviews[0], DemoFixtures.olderReviews[0]],
            nextPage: nil
        )
    }
}

private actor SlowCancellationProvider: DashboardDataProviding {
    func fetchApps() -> [DeveloperApp] {
        [DemoFixtures.dashboards[0].app]
    }

    func fetchDashboard(for app: DeveloperApp) async throws -> AppDashboard {
        try await Task.sleep(for: .seconds(10))
        return DemoFixtures.dashboards[0]
    }

    func fetchReviewsPage(at url: URL) -> ReviewPage {
        ReviewPage(reviews: [], nextPage: nil)
    }
}

private final class PagingURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case pages
        case repeating
        case malformed
        case authenticationRetry
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuredMode: Mode = .pages
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var urls: [URL] = []

    static var requestCount: Int {
        lock.withLock { attempts }
    }

    static var requestedURLs: [URL] {
        lock.withLock { urls }
    }

    static func configure(_ mode: Mode) {
        lock.withLock {
            configuredMode = mode
            attempts = 0
            urls = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (mode, attempt) = Self.lock.withLock { () -> (Mode, Int) in
            Self.attempts += 1
            if let url = request.url { Self.urls.append(url) }
            return (Self.configuredMode, Self.attempts)
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let status: Int
        let data: Data
        if mode == .authenticationRetry, attempt == 1 {
            status = 401
            data = Data(#"{"errors":[{"code":"NOT_AUTHORIZED"}]}"#.utf8)
        } else if mode == .malformed {
            status = 200
            data = Data("{ malformed".utf8)
        } else {
            status = 200
            let hasCursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "cursor" }) == true
            let resourceIDs = hasCursor && mode == .pages ? ["app-2", "app-1"] : ["app-1"]
            let resources: [[String: Any]] = resourceIDs.map { id in
                [
                    "type": "apps",
                    "id": id,
                    "attributes": [
                        "name": id == "app-1" ? "Alpha" : "Beta",
                        "bundleId": "com.example.\(id)",
                        "sku": id.uppercased(),
                        "primaryLocale": "en-US"
                    ]
                ]
            }
            let next: Any
            if mode == .repeating {
                next = url.absoluteString
            } else if mode == .pages && !hasCursor {
                next = "https://api.appstoreconnect.apple.com/v1/apps?cursor=next"
            } else {
                next = NSNull()
            }
            data = (try? JSONSerialization.data(withJSONObject: [
                "data": resources,
                "links": ["self": url.absoluteString, "next": next]
            ])) ?? Data()
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
