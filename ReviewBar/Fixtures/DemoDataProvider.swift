import Foundation

actor DemoDataProvider: DashboardDataProviding {
    enum Scenario: Sendable {
        case standard
        case empty
        case failure(AppError)
    }

    private let scenario: Scenario
    private let delay: Duration

    init(scenario: Scenario = .standard, delay: Duration = .milliseconds(180)) {
        self.scenario = scenario
        self.delay = delay
    }

    func fetchApps() async throws -> [DeveloperApp] {
        try await simulateRequest()
        switch scenario {
        case .standard: return DemoFixtures.dashboards.map(\.app)
        case .empty: return []
        case .failure(let error): throw error
        }
    }

    func fetchDashboard(for app: DeveloperApp) async throws -> AppDashboard {
        try await simulateRequest()
        if case .failure(let error) = scenario { throw error }
        guard var dashboard = DemoFixtures.dashboards.first(where: { $0.id == app.id }) else {
            throw AppError(kind: .malformedResponse, message: "The demo fixture is incomplete.")
        }
        dashboard.fetchedAt = .now
        return dashboard
    }

    func fetchReviewsPage(at url: URL) async throws -> ReviewPage {
        try await simulateRequest()
        guard url.scheme == "reviewbar-demo" else {
            throw AppError(kind: .malformedResponse, message: "The demo pagination link is invalid.")
        }
        return ReviewPage(reviews: DemoFixtures.olderReviews, nextPage: nil)
    }

    private func simulateRequest() async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
    }
}
