import Foundation

struct ReleaseObservation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let appID: String
    let releaseID: String
    let version: String
    let state: ReleaseState
    let observedAt: Date
    let source: Source

    enum Source: String, Codable, Hashable, Sendable {
        case apple
        case localObservation

        var label: String {
            switch self {
            case .apple: "Apple timestamp"
            case .localObservation: "Observed by ReviewBar"
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

