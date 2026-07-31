import Foundation

actor DashboardRepository {
    private let provider: any DashboardDataProviding
    private let cache: any SnapshotCaching
    private let historyStore: ReleaseHistoryStore
    private let readStore: ReviewReadStore

    init(
        provider: any DashboardDataProviding,
        cache: any SnapshotCaching,
        historyStore: ReleaseHistoryStore,
        readStore: ReviewReadStore
    ) {
        self.provider = provider
        self.cache = cache
        self.historyStore = historyStore
        self.readStore = readStore
    }

    func cached() async throws -> DashboardCollection? {
        try await cache.load()
    }

    func refresh() async throws -> DashboardCollection {
        let apps = try await provider.fetchApps()
        var dashboards: [AppDashboard] = []
        dashboards.reserveCapacity(apps.count)

        for batchStart in stride(from: 0, to: apps.count, by: 4) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + 4, apps.count)
            let batch = Array(apps[batchStart..<batchEnd])
            let results = try await withThrowingTaskGroup(of: AppDashboard.self) { group in
                for app in batch {
                    group.addTask { [provider] in
                        try await provider.fetchDashboard(for: app)
                    }
                }
                var values: [AppDashboard] = []
                for try await dashboard in group {
                    values.append(dashboard)
                }
                return values
            }
            dashboards.append(contentsOf: results)
        }

        let order = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($0.element.id, $0.offset) })
        dashboards.sort { order[$0.id, default: .max] < order[$1.id, default: .max] }
        let collection = DashboardCollection(dashboards: dashboards, fetchedAt: .now)

        for dashboard in dashboards {
            try await historyStore.record(dashboard.releases, appID: dashboard.id)
            try await readStore.reconcile(appID: dashboard.id, reviews: dashboard.reviews)
        }
        try await cache.save(collection)
        return collection
    }

    func loadMoreReviews(for appID: String, in collection: DashboardCollection) async throws -> DashboardCollection {
        guard let dashboardIndex = collection.dashboards.firstIndex(where: { $0.id == appID }),
              let nextPage = collection.dashboards[dashboardIndex].nextReviewsPage else {
            return collection
        }
        let page = try await provider.fetchReviewsPage(at: nextPage)
        var updated = collection
        let existingIDs = Set(updated.dashboards[dashboardIndex].reviews.map(\.id))
        updated.dashboards[dashboardIndex].reviews.append(
            contentsOf: page.reviews.filter { !existingIDs.contains($0.id) }
        )
        updated.dashboards[dashboardIndex].nextReviewsPage = page.nextPage
        // Later pages contain historical reviews. Discovering them must not turn them into new alerts.
        try await readStore.markAllRead(page.reviews)
        try await cache.save(updated)
        return updated
    }
}
