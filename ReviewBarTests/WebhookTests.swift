import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

@Suite(.serialized)
struct WebhookTests {
    @Test("Apple webhook creation uses the documented JSON:API shape")
    func createWebhook() async throws {
        WebhookURLProtocol.configure(status: 201)
        let provider = try makeProvider()
        let relayURL = try #require(URL(string: "https://relay.example/v1/apple/channel"))

        let webhook = try await provider.create(
            appID: "app-123",
            appName: "Universal App",
            url: relayURL,
            secret: "test-secret-not-a-real-credential",
            eventTypes: [.appVersionStateUpdated, .buildUploadStateUpdated]
        )

        #expect(webhook.id == "webhook-1")
        let request = try #require(WebhookURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/webhooks")
        let body = try #require(WebhookURLProtocol.lastBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["type"] as? String == "webhooks")
        let attributes = try #require(data["attributes"] as? [String: Any])
        #expect(attributes["enabled"] as? Bool == true)
        #expect(attributes["url"] as? String == relayURL.absoluteString)
        #expect(attributes["secret"] as? String == "test-secret-not-a-real-credential")
        #expect(attributes["eventTypes"] as? [String] == [
            "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
            "BUILD_UPLOAD_STATE_UPDATED"
        ])
        let relationships = try #require(data["relationships"] as? [String: Any])
        let app = try #require(relationships["app"] as? [String: Any])
        let relationshipData = try #require(app["data"] as? [String: Any])
        #expect(relationshipData["type"] as? String == "apps")
        #expect(relationshipData["id"] as? String == "app-123")
    }

    @Test("Apple webhook role denial remains a permission error")
    func permissionFailure() async throws {
        WebhookURLProtocol.configure(status: 403)
        let provider = try makeProvider()
        let relayURL = try #require(URL(string: "https://relay.example/v1/apple/channel"))

        do {
            _ = try await provider.create(
                appID: "app-123",
                appName: "App",
                url: relayURL,
                secret: "test-secret",
                eventTypes: [.appVersionStateUpdated]
            )
            Issue.record("Expected Apple's role denial")
        } catch let error as AppError {
            #expect(error.kind == .insufficientPermission)
            #expect(error.requestWasRejected)
        }
    }

    @Test("Webhook delete and ping use their documented endpoints")
    func deleteAndPing() async throws {
        WebhookURLProtocol.configure(status: 204)
        let provider = try makeProvider()
        try await provider.delete(webhookID: "webhook-1")
        #expect(WebhookURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(WebhookURLProtocol.lastRequest?.url?.path == "/v1/webhooks/webhook-1")

        WebhookURLProtocol.configure(status: 201)
        try await provider.ping(webhookID: "webhook-1")
        let request = try #require(WebhookURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/webhookPings")
        let body = try #require(WebhookURLProtocol.lastBody)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("webhookPings"))
        #expect(text.contains("webhook-1"))
    }

    @Test("Webhook deletion is idempotent when Apple reports it already absent")
    func deleteAlreadyAbsent() async throws {
        WebhookURLProtocol.configure(status: 404)
        let provider = try makeProvider()
        try await provider.delete(webhookID: "already-removed")
        #expect(WebhookURLProtocol.lastRequest?.httpMethod == "DELETE")
    }

    @Test("Ambiguous webhook creation is reconciled by its exact callback URL")
    func reconcileWebhookByURL() async throws {
        WebhookURLProtocol.configure(status: 200)
        let provider = try makeProvider()
        let callback = try #require(URL(string: "https://relay.example/apple/channel-1"))
        let matches = try await provider.matchingWebhooks(appID: "app-123", url: callback)
        #expect(matches.map(\.id) == ["webhook-matching"])
        #expect(WebhookURLProtocol.lastRequest?.httpMethod == "GET")
        #expect(WebhookURLProtocol.lastRequest?.url?.path == "/v1/apps/app-123/webhooks")
    }

    @Test("Relay event feed accepts fractional Apple timestamps")
    func relayEventDates() async throws {
        RelayURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try NotificationRelayClient(
            baseURL: #require(URL(string: "https://relay.example/")),
            session: session
        )
        let installation = RealtimeInstallation(
            id: "installation-1",
            token: "opaque-installation-token",
            channels: [],
            lastEventSync: nil
        )

        let batch = try await client.events(installation: installation)
        let events = batch.events
        #expect(events.count == 2)
        #expect(events[0].eventID == "event-1")
        #expect(events[1].eventID == "event-2")
        #expect(events[0].authoritativeTimestamp != nil)
        #expect(batch.checkpointCursor == "checkpoint-2")
        #expect(RelayURLProtocol.lastAuthorization == "Bearer opaque-installation-token")
    }

    private func makeProvider() throws -> AppStoreConnectWebhookProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebhookURLProtocol.self]
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
        return AppStoreConnectWebhookProvider(
            transport: transport,
            baseURL: URL(string: "https://api.appstoreconnect.apple.com/v1")!
        )
    }
}

private final class WebhookURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseStatus = 201
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?

    static var lastRequest: URLRequest? { lock.withLock { capturedRequest } }
    static var lastBody: Data? { lock.withLock { capturedBody } }

    static func configure(status: Int) {
        lock.withLock {
            responseStatus = status
            capturedRequest = nil
            capturedBody = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        let status = Self.lock.withLock { () -> Int in
            Self.capturedRequest = request
            Self.capturedBody = bodyData
            return Self.responseStatus
        }
        let body: Data
        if status == 403 {
            body = Data(#"{"errors":[{"code":"FORBIDDEN"}]}"#.utf8)
        } else if request.httpMethod == "GET", request.url?.path.hasSuffix("/webhooks") == true {
            body = Data(#"{"data":[{"type":"webhooks","id":"webhook-other","attributes":{"enabled":true,"eventTypes":["BUILD_UPLOAD_STATE_UPDATED"],"name":"Other","url":"https://relay.example/apple/other"}},{"type":"webhooks","id":"webhook-matching","attributes":{"enabled":true,"eventTypes":["APP_STORE_VERSION_APP_VERSION_STATE_UPDATED"],"name":"ReviewBar","url":"https://relay.example/apple/channel-1"}}],"links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/app-123/webhooks"}}"#.utf8)
        } else if request.url?.path.hasSuffix("/webhooks") == true {
            body = Data(#"{"data":{"type":"webhooks","id":"webhook-1","attributes":{"enabled":true,"eventTypes":["APP_STORE_VERSION_APP_VERSION_STATE_UPDATED","BUILD_UPLOAD_STATE_UPDATED"],"name":"ReviewBar – Universal App","url":"https://relay.example/v1/apple/channel"}}}"#.utf8)
        } else {
            body = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var authorization: String?
    static var lastAuthorization: String? { lock.withLock { authorization } }
    static func reset() { lock.withLock { authorization = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.authorization = request.value(forHTTPHeaderField: "Authorization") }
        let hasCursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "cursor" }) == true
        let body = hasCursor
            ? Data(#"{"events":[{"event_id":"event-2","channel_id":"channel-1","event_type":"buildUploadStateUpdated","instance_id":"upload-1","old_state":null,"new_state":"COMPLETE","authoritative_timestamp":null,"received_at":"2026-08-01T06:10:13.456Z"}],"nextCursor":null,"checkpointCursor":"checkpoint-2"}"#.utf8)
            : Data(#"{"events":[{"event_id":"event-1","channel_id":"channel-1","event_type":"appStoreVersionAppVersionStateUpdated","instance_id":"release-1","old_state":"WAITING_FOR_REVIEW","new_state":"IN_REVIEW","authoritative_timestamp":"2026-08-01T06:10:11.123Z","received_at":"2026-08-01T06:10:12.456Z"}],"nextCursor":"cursor-value","checkpointCursor":"checkpoint-1"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
