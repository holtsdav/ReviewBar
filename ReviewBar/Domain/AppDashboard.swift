import Foundation

struct AppDashboard: Identifiable, Codable, Hashable, Sendable {
    var app: DeveloperApp
    var releases: [AppRelease]
    var reviews: [CustomerReview]
    var builds: [BuildInfo]
    var nextReviewsPage: URL?
    var fetchedAt: Date
    var sectionIssues: [DashboardSection: SectionIssue] = [:]

    var id: String { app.id }
    var availablePlatforms: [AppRelease.Platform] {
        let values = Set(releases.map(\.platform) + builds.map(\.platform))
        return values.sorted { $0.sortOrder < $1.sortOrder }
    }
    var preferredPlatform: AppRelease.Platform? {
        currentRelease?.platform ?? latestBuild?.platform ?? availablePlatforms.first
    }
    var currentRelease: AppRelease? {
        currentRelease(in: nil)
    }
    var distributionReadyRelease: AppRelease? { distributionReadyRelease(in: nil) }
    var latestBuild: BuildInfo? { latestBuild(in: nil) }
    var newestReview: CustomerReview? { reviews.first }

    func currentRelease(in platform: AppRelease.Platform?) -> AppRelease? {
        let candidates = platform.map { selected in releases.filter { $0.platform == selected } } ?? releases
        return candidates.first(where: {
            ![ReleaseState.readyForDistribution, .replacedWithNewVersion].contains($0.state)
        }) ?? candidates.first(where: { $0.state == .readyForDistribution }) ?? candidates.first
    }

    func distributionReadyRelease(in platform: AppRelease.Platform?) -> AppRelease? {
        let candidates = platform.map { selected in releases.filter { $0.platform == selected } } ?? releases
        return candidates.first(where: { $0.state == .readyForDistribution })
    }

    func latestBuild(in platform: AppRelease.Platform?) -> BuildInfo? {
        guard let platform else { return builds.first }
        return builds.first(where: { $0.platform == platform })
    }
}

enum DashboardSection: String, Codable, Hashable, Sendable {
    case releases
    case reviews
    case builds
    case analytics
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
