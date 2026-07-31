import Foundation

protocol DashboardDataProviding: Sendable {
    func fetchApps() async throws -> [DeveloperApp]
    func fetchDashboard(for app: DeveloperApp) async throws -> AppDashboard
    func fetchReviewsPage(at url: URL) async throws -> ReviewPage
}

struct ReviewPage: Sendable {
    let reviews: [CustomerReview]
    let nextPage: URL?
}

