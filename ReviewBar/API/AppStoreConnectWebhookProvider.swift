import Foundation

struct AppStoreConnectWebhookProvider: Sendable {
    private let transport: AppleAPITransport
    private let baseURL: URL

    init(credential: AppStoreConnectCredential) throws {
        guard let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1") else {
            throw AppError(kind: .other, message: "ReviewBar's Apple webhook API address is invalid.")
        }
        transport = AppleAPITransport(signer: try JWTGenerator(credential: credential))
        self.baseURL = baseURL
    }

    init(transport: AppleAPITransport, baseURL: URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    func create(
        appID: String,
        appName: String,
        url: URL,
        secret: String,
        eventTypes: [AppStoreConnectWebhookEventType]
    ) async throws -> WebhookAPIResource {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              !secret.isEmpty, !eventTypes.isEmpty else {
            throw AppError(kind: .other, message: "The notification relay returned an invalid webhook configuration.")
        }
        let payload: [String: Any] = [
            "data": [
                "type": "webhooks",
                "attributes": [
                    "enabled": true,
                    "eventTypes": eventTypes.map(\.rawValue),
                    "name": String("ReviewBar – \(appName)".prefix(200)),
                    "secret": secret,
                    "url": url.absoluteString
                ],
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appID]]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = try await transport.post(baseURL.appending(path: "webhooks"), body: body)
        return try AppleAPIDecoder.make().decode(
            JSONAPISingle<WebhookAPIResource>.self,
            from: response.data
        ).data
    }

    func delete(webhookID: String) async throws {
        _ = try await transport.delete(baseURL.appending(path: "webhooks/\(webhookID)"))
    }

    /// Reconciles an ambiguous create response by the exact, installation-
    /// scoped callback URL that ReviewBar persisted before issuing the POST.
    func matchingWebhooks(appID: String, url callbackURL: URL) async throws -> [WebhookAPIResource] {
        let initialURL = baseURL.appending(path: "apps/\(appID)/webhooks")
        guard var components = URLComponents(url: initialURL, resolvingAgainstBaseURL: false) else {
            throw AppError(kind: .other, message: "ReviewBar couldn't create a webhook reconciliation request.")
        }
        components.queryItems = [
            URLQueryItem(name: "fields[webhooks]", value: "enabled,eventTypes,name,url"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let firstURL = components.url else {
            throw AppError(kind: .other, message: "ReviewBar couldn't encode a webhook reconciliation request.")
        }

        var nextURL: URL? = firstURL
        var visited: Set<URL> = []
        var matches: [WebhookAPIResource] = []
        var pageCount = 0
        while let url = nextURL {
            try Task.checkCancellation()
            guard visited.insert(url).inserted, pageCount < 100 else {
                throw AppError(kind: .malformedResponse, message: "Apple returned a repeating webhook pagination chain.")
            }
            let response = try await transport.get(url)
            let page = try AppleAPIDecoder.make().decode(
                JSONAPIPage<WebhookAPIResource, EmptyIncluded>.self,
                from: response.data
            )
            matches.append(contentsOf: page.data.filter { $0.attributes.url == callbackURL })
            nextURL = page.links.next
            pageCount += 1
        }
        return matches
    }

    func ping(webhookID: String) async throws {
        let payload: [String: Any] = [
            "data": [
                "type": "webhookPings",
                "relationships": [
                    "webhook": ["data": ["type": "webhooks", "id": webhookID]]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        _ = try await transport.post(baseURL.appending(path: "webhookPings"), body: body)
    }
}
