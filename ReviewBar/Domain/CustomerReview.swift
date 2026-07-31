import Foundation

struct CustomerReview: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let rating: Int
    let title: String
    let body: String
    let reviewerNickname: String
    let territory: String?
    let createdDate: Date
    let appVersion: String?
    let developerResponseState: DeveloperResponseState?

    var hasDeveloperResponse: Bool { developerResponseState != nil }
}

struct DeveloperResponseState: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(apiValue: String) { rawValue = apiValue }

    static let published = Self(rawValue: "PUBLISHED")
    static let pendingPublish = Self(rawValue: "PENDING_PUBLISH")

    var title: String {
        switch rawValue {
        case Self.published.rawValue: "Developer response published"
        case Self.pendingPublish.rawValue: "Developer response awaiting publication"
        default: "Developer response: \(rawValue.displayStatus)"
        }
    }

    var symbol: String {
        self == .published ? "arrowshape.turn.up.left.fill" : "clock.badge"
    }
}
