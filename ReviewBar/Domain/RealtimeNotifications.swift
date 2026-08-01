import Foundation

struct RealtimeChannel: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let appID: String
    let appName: String
    let appleWebhookID: String
    let eventTypes: [AppStoreConnectWebhookEventType]
}

/// Durable compensation metadata written before Apple webhook confirmation.
/// If setup or its rollback loses connectivity, ReviewBar retains both server
/// identifiers and the installation bearer needed to retry cleanup.
struct RealtimePendingCleanup: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let appID: String
    let appName: String
    let webhookURL: URL?
    var appleWebhookIDs: [String]
}

struct RealtimeInstallation: Codable, Hashable, Sendable {
    let id: String
    let token: String
    var channels: [RealtimeChannel]
    var pendingCleanup: [RealtimePendingCleanup]
    var lastEventSync: Date?
    var lastEventCursor: String?
    var relayBaseURL: URL?

    init(
        id: String,
        token: String,
        channels: [RealtimeChannel],
        pendingCleanup: [RealtimePendingCleanup] = [],
        lastEventSync: Date?,
        lastEventCursor: String? = nil,
        relayBaseURL: URL? = nil
    ) {
        self.id = id
        self.token = token
        self.channels = channels
        self.pendingCleanup = pendingCleanup
        self.lastEventSync = lastEventSync
        self.lastEventCursor = lastEventCursor
        self.relayBaseURL = relayBaseURL
    }

    enum CodingKeys: String, CodingKey {
        case id, token, channels, pendingCleanup, lastEventSync, lastEventCursor, relayBaseURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        token = try container.decode(String.self, forKey: .token)
        channels = try container.decode([RealtimeChannel].self, forKey: .channels)
        pendingCleanup = try container.decodeIfPresent([RealtimePendingCleanup].self, forKey: .pendingCleanup) ?? []
        lastEventSync = try container.decodeIfPresent(Date.self, forKey: .lastEventSync)
        lastEventCursor = try container.decodeIfPresent(String.self, forKey: .lastEventCursor)
        relayBaseURL = try container.decodeIfPresent(URL.self, forKey: .relayBaseURL)
    }
}

struct RelayEventBatch: Sendable {
    let events: [RelayEvent]
    /// Opaque relay-issued tuple cursor. Unlike a timestamp watermark, this
    /// cannot skip two events received at the same instant.
    let checkpointCursor: String?
}

struct RelayEvent: Decodable, Sendable {
    let eventID: String
    let channelID: String
    let eventType: String
    let instanceID: String?
    let oldState: String?
    let newState: String?
    let authoritativeTimestamp: Date?
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case channelID = "channel_id"
        case eventType = "event_type"
        case instanceID = "instance_id"
        case oldState = "old_state"
        case newState = "new_state"
        case authoritativeTimestamp = "authoritative_timestamp"
        case receivedAt = "received_at"
    }
}

enum RealtimeSetupState: Equatable, Sendable {
    case loading
    case ready
    case configuring(appID: String)
    case unavailable(String)
    case failed(String)
}
