import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

@Suite(.serialized)
struct IconTests {
    @Test("ImageAsset templates resolve official width, height, and format tokens")
    func imageAssetTemplate() throws {
        let asset = AppIconAsset(
            templateURL: try #require(URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Purple/app.png/{w}x{h}.{f}")),
            width: 1024,
            height: 1024,
            source: .appStore
        )
        #expect(asset.resolvedURL(pointSize: 60, scale: 3)?.absoluteString.hasSuffix("/180x180.png") == true)
        #expect(asset.resolvedURL(pointSize: 0) == nil)
    }

    @Test("Apps map their official App Store icon without scraping")
    func officialAppStoreIcon() async throws {
        IconAPIURLProtocol.configure(.appIcon)
        let provider = try makeProvider()
        let apps = try await provider.fetchApps()
        let icon = try #require(apps.first?.iconAsset)
        #expect(icon.source == .appStore)
        #expect(icon.width == 1024)
        #expect(icon.resolvedURL(pointSize: 64)?.host == "cdn.example.com")
    }

    @Test("The newest suitable build icon is used when an app has no App Store icon")
    func buildIconFallback() async throws {
        IconAPIURLProtocol.configure(.buildFallback)
        let provider = try makeProvider()
        let app = DeveloperApp(
            id: "app",
            name: "Beta Only",
            bundleID: "com.example.beta",
            sku: nil,
            primaryLocale: nil
        )
        let dashboard = try await provider.fetchDashboard(for: app)
        #expect(dashboard.builds.map(\.platform) == [AppRelease.Platform.macOS, .iOS])
        #expect(dashboard.app.iconAsset?.source == .build)
        #expect(dashboard.app.iconAsset?.templateURL.host == "cdn.example.com")
    }

    @Test("Downloaded icons are served offline from the local cache")
    func iconCache() async throws {
        IconAPIURLProtocol.configure(.imageSuccess)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconAPIURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppIconCache(directoryURL: directory, session: URLSession(configuration: configuration))
        let url = try #require(URL(string: "https://cdn.example.com/icon.png"))

        let first = try await cache.data(for: url)
        IconAPIURLProtocol.configure(.imageOffline, preserveCount: true)
        let cached = try await cache.data(for: url)
        #expect(first == cached)
        #expect(IconAPIURLProtocol.requestCount == 1)
        #expect(await cache.sizeInBytes() == Int64(first.count))
    }

    @Test("Broken icon responses do not poison the cache")
    func brokenIcon() async throws {
        IconAPIURLProtocol.configure(.imageBroken)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconAPIURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppIconCache(directoryURL: directory, session: URLSession(configuration: configuration))
        let url = try #require(URL(string: "https://cdn.example.com/missing.png"))
        await #expect(throws: AppError.self) { try await cache.data(for: url) }
        #expect(await cache.sizeInBytes() == 0)
    }

    @Test("A corrupt 200 image response is rejected before it can poison the cache")
    func corruptSuccessfulIcon() async throws {
        IconAPIURLProtocol.configure(.imageCorrupt)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconAPIURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppIconCache(directoryURL: directory, session: URLSession(configuration: configuration))
        let url = try #require(URL(string: "https://cdn.example.com/corrupt.png"))
        await #expect(throws: AppError.self) { try await cache.data(for: url) }
        #expect(await cache.sizeInBytes() == 0)
    }

    private func makeProvider() throws -> AppStoreConnectDataProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconAPIURLProtocol.self]
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            scope: .individual
        )
        let transport = AppleAPITransport(
            signer: try JWTGenerator(credential: credential),
            session: URLSession(configuration: configuration)
        )
        return AppStoreConnectDataProvider(
            transport: transport,
            baseURL: try #require(URL(string: "https://api.appstoreconnect.apple.com/v1"))
        )
    }
}

private final class IconAPIURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case appIcon, buildFallback, imageSuccess, imageOffline, imageBroken, imageCorrupt }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .appIcon
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func configure(_ newMode: Mode, preserveCount: Bool = false) {
        lock.withLock {
            mode = newMode
            if !preserveCount { count = 0 }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mode = Self.lock.withLock { () -> Mode in
            Self.count += 1
            return Self.mode
        }
        let url = request.url ?? URL(string: "https://invalid.example")!
        let response: HTTPURLResponse
        let data: Data

        switch mode {
        case .imageSuccess:
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") ?? Data()
        case .imageOffline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case .imageBroken:
            response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
            data = Data("not found".utf8)
        case .imageCorrupt:
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            data = Data("not actually an image".utf8)
        case .appIcon:
            response = jsonResponse(url)
            data = Data(#"{"data":[{"type":"apps","id":"app","attributes":{"name":"Icon App","bundleId":"com.example.icon","sku":"ICON","primaryLocale":"en-US"},"relationships":{"appStoreIcon":{"data":{"type":"buildIcons","id":"icon-store"}}}}],"included":[{"type":"buildIcons","id":"icon-store","attributes":{"iconAsset":{"templateUrl":"https://cdn.example.com/{w}x{h}.{f}","width":1024,"height":1024},"iconType":"APP_STORE","masked":false,"name":"App Store"}}],"links":{"self":"https://api.appstoreconnect.apple.com/v1/apps"}}"#.utf8)
        case .buildFallback:
            response = jsonResponse(url)
            data = buildFallbackResponse(for: url)
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func jsonResponse(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    private func buildFallbackResponse(for url: URL) -> Data {
        switch url.path {
        case let path where path.hasSuffix("/appStoreVersions"),
             let path where path.hasSuffix("/reviewSubmissions"),
             let path where path.hasSuffix("/customerReviews"):
            return Data("{\"data\":[],\"links\":{\"self\":\"\(url.absoluteString)\"}}".utf8)
        case let path where path.hasSuffix("/builds"):
            return Data(#"{"data":[{"type":"builds","id":"mac-build","attributes":{"version":"7","uploadedDate":"2026-07-31T12:00:00Z","expirationDate":null,"expired":false,"processingState":"VALID","minOsVersion":"15.0","buildAudienceType":"APP_STORE_ELIGIBLE"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"pre-mac"}},"icons":{"data":[{"type":"buildIcons","id":"build-icon"}]} }},{"type":"builds","id":"ios-build","attributes":{"version":"8","uploadedDate":"2026-07-30T12:00:00Z","expirationDate":null,"expired":false,"processingState":"VALID","minOsVersion":"18.0","buildAudienceType":"APP_STORE_ELIGIBLE"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"pre-ios"}},"icons":{"data":[]}}}],"included":[{"type":"preReleaseVersions","id":"pre-mac","attributes":{"version":"1.0","platform":"MAC_OS"}},{"type":"preReleaseVersions","id":"pre-ios","attributes":{"version":"1.0","platform":"IOS"}},{"type":"buildIcons","id":"build-icon","attributes":{"iconAsset":{"templateUrl":"https://cdn.example.com/build/{w}x{h}.{f}","width":512,"height":512},"iconType":"APP_STORE","masked":false,"name":"Binary Icon"}}],"links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}"#.utf8)
        default:
            return Data("{\"data\":[],\"links\":{\"self\":\"\(url.absoluteString)\"}}".utf8)
        }
    }
}
