import Foundation

actor DemoAnalyticsProvider: AnalyticsDataProviding {
    enum Scenario: Sendable {
        case available
        case notEnabled
        case generating
        case stopped
        case failure(AppError)
    }

    private var scenario: Scenario

    init(scenario: Scenario = .available) {
        self.scenario = scenario
    }

    func fetchAnalytics(appID: String) throws -> AnalyticsFetchResult {
        switch scenario {
        case .available: .dataset(DemoFixtures.analytics(appID: appID))
        case .notEnabled: .notEnabled
        case .generating: .generating
        case .stopped: .stoppedDueToInactivity
        case .failure(let error): throw error
        }
    }

    func createOngoingRequest(appID: String) {
        scenario = .generating
    }
}
