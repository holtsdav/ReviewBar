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
            ![ReleaseState.readyForDistribution, .replacedWithNewVersion].contains($0.state)
        }) ?? distributionReadyRelease ?? releases.first
    }
    var distributionReadyRelease: AppRelease? { releases.first(where: { $0.state == .readyForDistribution }) }
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
    let usingCachedData: Bool?
    let cachedAt: Date?

    init(error: Error) {
        let mapped = AppError.map(error)
        message = mapped.message
        usingCachedData = false
        cachedAt = nil
        switch mapped.kind {
        case .insufficientPermission: kind = .permission
        case .offline: kind = .offline
        case .rateLimited: kind = .rateLimited
        case .appleUnavailable: kind = .unavailable
        case .malformedResponse: kind = .malformedResponse
        default: kind = .other
        }
    }

    private init(kind: Kind, message: String, usingCachedData: Bool, cachedAt: Date?) {
        self.kind = kind
        self.message = message
        self.usingCachedData = usingCachedData
        self.cachedAt = cachedAt
    }

    func fallingBackToCache(from date: Date) -> SectionIssue {
        SectionIssue(kind: kind, message: message, usingCachedData: true, cachedAt: date)
    }
}

struct DashboardCollection: Codable, Hashable, Sendable {
    var dashboards: [AppDashboard]
    var fetchedAt: Date

    var hasStaleSections: Bool {
        dashboards.contains { dashboard in
            dashboard.sectionIssues.values.contains { $0.usingCachedData == true }
        }
    }
}
