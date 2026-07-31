import Foundation

struct AppDashboard: Identifiable, Codable, Hashable, Sendable {
    let app: DeveloperApp
    var releases: [AppRelease]
    var reviews: [CustomerReview]
    var builds: [BuildInfo]
    var nextReviewsPage: URL?
    var fetchedAt: Date
    var sectionIssues: [DashboardSection: SectionIssue] = [:]

    var id: String { app.id }
    var currentRelease: AppRelease? {
        releases.first(where: {
            ![ReleaseState.accepted, .readyForDistribution, .replacedWithNewVersion].contains($0.state)
        }) ?? liveRelease ?? releases.first
    }
    var liveRelease: AppRelease? { releases.first(where: { $0.state == .readyForDistribution }) }
    var latestBuild: BuildInfo? { builds.first }
    var newestReview: CustomerReview? { reviews.first }
}

enum DashboardSection: String, Codable, Hashable, Sendable {
    case releases
    case reviews
    case builds
}

struct SectionIssue: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case permission
        case offline
        case rateLimited
        case unavailable
        case malformedResponse
        case other
    }

    let kind: Kind
    let message: String

    init(error: Error) {
        let mapped = AppError.map(error)
        message = mapped.message
        switch mapped.kind {
        case .insufficientPermission: kind = .permission
        case .offline: kind = .offline
        case .rateLimited: kind = .rateLimited
        case .appleUnavailable: kind = .unavailable
        case .malformedResponse: kind = .malformedResponse
        default: kind = .other
        }
    }
}

struct DashboardCollection: Codable, Hashable, Sendable {
    var dashboards: [AppDashboard]
    var fetchedAt: Date
}
