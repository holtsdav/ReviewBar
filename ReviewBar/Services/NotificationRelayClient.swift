import Foundation

struct NotificationRelayConfiguration: Sendable {
    let baseURL: URL?

    static var bundled: NotificationRelayConfiguration {
        let value = Bundle.main.object(forInfoDictionaryKey: "ReviewBarRelayBaseURL") as? String
        let url = value.flatMap(URL.init(string:)).flatMap { candidate -> URL? in
            guard candidate.scheme?.lowercased() == "https",
                  candidate.host != nil,
                  candidate.user == nil,
                  candidate.password == nil,
                  (candidate.path.isEmpty || candidate.path == "/"),
                  candidate.query == nil,
                  candidate.fragment == nil else { return nil }
            return candidate
        }
        return NotificationRelayConfiguration(baseURL: url)
    }
}

struct RelayChannelConfiguration: Decodable, Sendable {
    let channelID: String
    let webhookURL: URL
    let secret: String
    let eventTypes: [String]
}

struct NotificationRelayClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession? = nil) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              (baseURL.path.isEmpty || baseURL.path == "/"),
              baseURL.query == nil, baseURL.fragment == nil else {
            throw AppError(kind: .other, message: "The ReviewBar notification relay URL is invalid.")
        }
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) ?? wholeSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO 8601 date"
            )
        }
        self.decoder = decoder
    }

    func register(apnsToken: String, environment: String) async throws -> RealtimeInstallation {
        struct Response: Decodable { let installationID: String; let token: String }
        let response: Response = try await request(
            path: "v1/installations",
            method: "POST",
            bearer: nil,
            body: ["apnsToken": apnsToken, "apnsEnvironment": environment]
        )
        return RealtimeInstallation(
            id: response.installationID,
            token: response.token,
            channels: [],
            lastEventSync: nil,
            lastEventCursor: nil,
            relayBaseURL: baseURL
        )
    }

    func rotateDeviceToken(_ apnsToken: String, environment: String, installation: RealtimeInstallation) async throws {
        let _: EmptyRelayResponse = try await request(
            path: "v1/installations/current/device-token",
            method: "PATCH",
            bearer: installation.token,
            body: ["apnsToken": apnsToken, "apnsEnvironment": environment]
        )
    }

    func createChannel(
        app: DeveloperApp,
        eventTypes: [AppStoreConnectWebhookEventType],
        installation: RealtimeInstallation
    ) async throws -> RelayChannelConfiguration {
        try await request(
            path: "v1/channels",
            method: "POST",
            bearer: installation.token,
            body: RelayChannelRequest(
                appID: app.id,
                appName: app.name,
                eventTypes: eventTypes.map(\.rawValue)
            )
        )
    }

    func confirm(channelID: String, webhookID: String, installation: RealtimeInstallation) async throws {
        let _: EmptyRelayResponse = try await request(
            path: "v1/channels/\(channelID)/confirm",
            method: "PATCH",
            bearer: installation.token,
            body: ["webhookID": webhookID]
        )
    }

    func deleteChannel(channelID: String, installation: RealtimeInstallation) async throws {
        try await requestWithoutResponse(
            path: "v1/channels/\(channelID)",
            method: "DELETE",
            bearer: installation.token
        )
    }

    func deleteInstallation(_ installation: RealtimeInstallation) async throws {
        try await requestWithoutResponse(
            path: "v1/installations/current",
            method: "DELETE",
            bearer: installation.token
        )
    }

    func events(installation: RealtimeInstallation) async throws -> RelayEventBatch {
        struct Response: Decodable {
            let events: [RelayEvent]
            let nextCursor: String?
            let checkpointCursor: String?
        }
        var path = "v1/events"
        if let cursor = installation.lastEventCursor,
           let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?cursor=\(encoded)"
        } else if let date = installation.lastEventSync {
            path += "?since=\(date.ISO8601Format().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        var events: [RelayEvent] = []
        var checkpointCursor: String?
        var pageCount = 0
        while true {
            let response: Response = try await request(
                path: path,
                method: "GET",
                bearer: installation.token,
                body: Optional<String>.none
            )
            events.append(contentsOf: response.events)
            if let responseCheckpoint = response.checkpointCursor {
                checkpointCursor = responseCheckpoint
            }
            pageCount += 1
            guard let cursor = response.nextCursor else { break }
            guard pageCount < 100,
                  let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw AppError(kind: .malformedResponse, message: "The notification relay returned an invalid pagination chain.")
            }
            path = "v1/events?cursor=\(encoded)"
        }
        let deduplicated = Array(Dictionary(
            events.map { ("\($0.channelID)|\($0.eventID)", $0) },
            uniquingKeysWith: { first, _ in first }
        ).values).sorted {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            if $0.eventID != $1.eventID { return $0.eventID < $1.eventID }
            return $0.channelID < $1.channelID
        }
        return RelayEventBatch(events: deduplicated, checkpointCursor: checkpointCursor)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        bearer: String?,
        body: Body?
    ) async throws -> Response {
        let (data, _) = try await perform(path: path, method: method, bearer: bearer, body: body)
        guard !data.isEmpty else {
            if let empty = EmptyRelayResponse() as? Response { return empty }
            throw AppError(kind: .malformedResponse, message: "The notification relay returned an empty response.")
        }
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw AppError(kind: .malformedResponse, message: "The notification relay returned an unexpected response.") }
    }

    private func requestWithoutResponse(
        path: String,
        method: String,
        bearer: String
    ) async throws {
        let _: (Data, HTTPURLResponse) = try await perform(
            path: path,
            method: method,
            bearer: bearer,
            body: Optional<String>.none
        )
    }

    private func perform<Body: Encodable>(
        path: String,
        method: String,
        bearer: String?,
        body: Body?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host else {
            throw AppError(kind: .other, message: "ReviewBar couldn't create a notification relay request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError(kind: .other, message: "The notification relay returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if method == "DELETE", http.statusCode == 404 { return (data, http) }
            switch http.statusCode {
            case 401: throw AppError(kind: .secureStorage, message: "This device's notification registration is no longer valid. Disable and re-enable real-time updates.")
            case 409: throw AppError(kind: .other, message: "This app already has a real-time notification channel on this device.")
            case 429: throw AppError(kind: .rateLimited(retryAfter: nil), message: "The notification relay is receiving too many requests. Try again later.")
            case 500...599: throw AppError(kind: .appleUnavailable, message: "The ReviewBar notification relay is temporarily unavailable.")
            default: throw AppError(kind: .other, message: "The notification relay rejected this request.")
            }
        }
        return (data, http)
    }
}

private struct EmptyRelayResponse: Codable {
    init() {}
}

private struct RelayChannelRequest: Encodable {
    let appID: String
    let appName: String
    let eventTypes: [String]
}
