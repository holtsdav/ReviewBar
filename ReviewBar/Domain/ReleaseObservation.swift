import Foundation

struct ReleaseObservation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let appID: String
    let releaseID: String
    let version: String
    let state: ReleaseState
    let observedAt: Date
    let source: Source
    var externalEventID: String? = nil

    enum Source: String, Codable, Hashable, Sendable {
        case apple
        case appleWebhook
        case localObservation

        var label: String {
            switch self {
            case .apple: "Apple API timestamp"
            case .appleWebhook: "Apple webhook timestamp"
            case .localObservation: "Observed by ReviewBar"
            }
        }

        var authority: Int {
            switch self {
            case .appleWebhook: 3
            case .apple: 2
            case .localObservation: 1
            }
        }
    }
}

struct ReleaseStatistics: Equatable, Sendable {
    let averageWaiting: TimeInterval?
    let averageInReview: TimeInterval?
    let fastestApproval: TimeInterval?
    let longestApproval: TimeInterval?
    let completedReleaseCount: Int
}
