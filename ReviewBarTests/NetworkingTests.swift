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

    @Test("Apple 405 errors become an actionable, cache-safe message")
    func methodNotAllowedMapping() {
        let data = Data(#"{"errors":[{"code":"METHOD_NOT_ALLOWED"}]}"#.utf8)
        let mapped = AppleHTTPErrorMapper.map(
            statusCode: 405,
            data: data,
            retryAfterHeader: nil
        )

        #expect(mapped.kind == .other)
        #expect(mapped.requestWasRejected)
        #expect(mapped.message.contains("undocumented"))
        #expect(mapped.message.contains("METHOD_NOT_ALLOWED"))
        #expect(mapped.message.contains("cached data is unchanged"))
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
        var saved = DemoFixtures.dashboards[0]
        saved.app.iconAsset = AppIconAsset(
            templateURL: try #require(URL(string: "https://cdn.example.com/cached/{w}x{h}.{f}")),
            width: 512,
            height: 512,
            source: .build
        )
        var refreshedApp = saved.app
        refreshedApp.iconAsset = nil
        let failedDashboard = AppDashboard(
            app: refreshedApp,
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
        #expect(refreshed.app.iconAsset == saved.app.iconAsset)
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
        #expect(queryItems?.contains(where: { $0.name.contains("platform") }) == false)
        #expect(queryItems?.contains(URLQueryItem(name: "include", value: "appStoreIcon")) == true)
        #expect(apps.first?.iconAsset?.source == .appStore)
    }

    @Test("Provider retains mixed-platform releases and builds without platform filters")
    func mixedPlatformDashboard() async throws {
        let provider = try makeHTTPProvider(mode: .multiPlatformDashboard)
        let storeIcon = AppIconAsset(
            templateURL: try #require(URL(string: "https://cdn.example.com/store/{w}x{h}.{f}")),
            width: 1024,
            height: 1024,
            source: .appStore
        )
        let app = DeveloperApp(
            id: "app",
            name: "Universal",
            bundleID: "com.example.universal",
            sku: nil,
            primaryLocale: nil,
            iconAsset: storeIcon
        )
        let dashboard = try await provider.fetchDashboard(for: app)
        #expect(Set(dashboard.releases.map(\.platform)) == [.iOS, .macOS, .tvOS, .visionOS])
        #expect(Set(dashboard.builds.map(\.platform)) == [.iOS, .macOS])
        #expect(dashboard.app.iconAsset == storeIcon)
        let allQueryNames = PagingURLProtocol.requestedURLs.compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        }.flatMap { $0 }
        #expect(allQueryNames.contains(where: { $0 == "filter[platform]" || $0 == "filter[preReleaseVersion.platform]" }) == false)
    }

    @Test("Build pagination retains platforms that appear after the first 200 results")
    func mixedPlatformBuildPagination() async throws {
        let provider = try makeHTTPProvider(mode: .multiPlatformBuildPages)
        let app = DeveloperApp(
            id: "app",
            name: "Universal",
            bundleID: "com.example.universal",
            sku: nil,
            primaryLocale: nil,
            iconAsset: nil
        )
        let dashboard = try await provider.fetchDashboard(for: app)
        #expect(Set(dashboard.builds.map(\.platform)) == [.iOS, .macOS])
        let buildRequests = PagingURLProtocol.requestedURLs.filter { $0.path.hasSuffix("/builds") }
        #expect(buildRequests.count == 2)
        #expect(buildRequests.contains { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                URLQueryItem(name: "cursor", value: "build-next")
            ) == true
        })
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
        case multiPlatformDashboard
        case multiPlatformBuildPages
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
        if mode == .multiPlatformDashboard || mode == .multiPlatformBuildPages {
            status = 200
            data = Self.multiPlatformResponse(for: url, paginateBuilds: mode == .multiPlatformBuildPages)
        } else if mode == .authenticationRetry, attempt == 1 {
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
                    ],
                    "relationships": [
                        "appStoreIcon": ["data": ["type": "buildIcons", "id": "shared-icon"]]
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
                "included": [[
                    "type": "buildIcons",
                    "id": "shared-icon",
                    "attributes": [
                        "iconAsset": [
                            "templateUrl": "https://cdn.example.com/{w}x{h}.{f}",
                            "width": 1024,
                            "height": 1024
                        ],
                        "iconType": "APP_STORE",
                        "masked": false,
                        "name": "Store"
                    ]
                ]],
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

    private static func multiPlatformResponse(for url: URL, paginateBuilds: Bool = false) -> Data {
        let json: String
        if url.path.hasSuffix("/appStoreVersions") {
            json = #"{"data":[{"type":"appStoreVersions","id":"ios","attributes":{"platform":"IOS","versionString":"2.0","appVersionState":"IN_REVIEW","releaseType":"MANUAL","createdDate":"2026-07-31T10:00:00Z"}},{"type":"appStoreVersions","id":"mac","attributes":{"platform":"MAC_OS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION","releaseType":"MANUAL","createdDate":"2026-07-30T10:00:00Z"}},{"type":"appStoreVersions","id":"tv","attributes":{"platform":"TV_OS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION","releaseType":"MANUAL","createdDate":"2026-07-29T10:00:00Z"}},{"type":"appStoreVersions","id":"vision","attributes":{"platform":"VISION_OS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION","releaseType":"MANUAL","createdDate":"2026-07-28T10:00:00Z"}}],"links":{}}"#
        } else if url.path.hasSuffix("/builds") {
            let hasCursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(URLQueryItem(name: "cursor", value: "build-next")) == true
            if paginateBuilds && !hasCursor {
                json = #"{"data":[{"type":"builds","id":"b-ios","attributes":{"version":"5","uploadedDate":"2026-07-31T12:00:00Z","expired":false,"processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-ios"}},"icons":{"data":[]}}}],"included":[{"type":"preReleaseVersions","id":"p-ios","attributes":{"version":"2.0","platform":"IOS"}}],"links":{"next":"https://api.appstoreconnect.apple.com/v1/builds?cursor=build-next"}}"#
            } else if paginateBuilds {
                json = #"{"data":[{"type":"builds","id":"b-mac","attributes":{"version":"4","uploadedDate":"2026-07-30T12:00:00Z","expired":false,"processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-mac"}},"icons":{"data":[{"type":"buildIcons","id":"binary-icon"}]}}}],"included":[{"type":"preReleaseVersions","id":"p-mac","attributes":{"version":"1.0","platform":"MAC_OS"}},{"type":"buildIcons","id":"binary-icon","attributes":{"iconAsset":{"templateUrl":"https://cdn.example.com/build/{w}x{h}.{f}","width":512,"height":512},"iconType":"APP_STORE"}}],"links":{}}"#
            } else {
                json = #"{"data":[{"type":"builds","id":"b-mac","attributes":{"version":"4","uploadedDate":"2026-07-31T12:00:00Z","expired":false,"processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-mac"}},"icons":{"data":[{"type":"buildIcons","id":"binary-icon"}]} }},{"type":"builds","id":"b-ios","attributes":{"version":"5","uploadedDate":"2026-07-30T12:00:00Z","expired":false,"processingState":"PROCESSING"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-ios"}},"icons":{"data":[]}}}],"included":[{"type":"preReleaseVersions","id":"p-mac","attributes":{"version":"1.0","platform":"MAC_OS"}},{"type":"preReleaseVersions","id":"p-ios","attributes":{"version":"2.0","platform":"IOS"}},{"type":"buildIcons","id":"binary-icon","attributes":{"iconAsset":{"templateUrl":"https://cdn.example.com/build/{w}x{h}.{f}","width":512,"height":512},"iconType":"APP_STORE"}}],"links":{}}"#
            }
        } else {
            json = #"{"data":[],"links":{}}"#
        }
        return Data(json.utf8)
    }
}
