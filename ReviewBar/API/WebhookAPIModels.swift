import Foundation

enum AppStoreConnectWebhookEventType: String, Codable, CaseIterable, Hashable, Sendable {
    case appVersionStateUpdated = "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED"
    case buildUploadStateUpdated = "BUILD_UPLOAD_STATE_UPDATED"
    case externalBuildStateUpdated = "BUILD_BETA_DETAIL_EXTERNAL_BUILD_STATE_UPDATED"
    case betaCrashFeedbackCreated = "BETA_FEEDBACK_CRASH_SUBMISSION_CREATED"
    case betaScreenshotFeedbackCreated = "BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED"
}

struct WebhookAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let enabled: Bool
        let eventTypes: [String]
        let name: String
        let url: URL
    }

    let type: String
    let id: String
    let attributes: Attributes
}

struct WebhookPingAPIResource: Decodable, Sendable {
    let type: String
    let id: String
}
