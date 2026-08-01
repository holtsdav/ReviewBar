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
        let previous = try? await cache.load()
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
        let previousByID = Dictionary(
            uniqueKeysWithValues: (previous?.dashboards ?? []).map { ($0.id, $0) }
        )
        var usedCachedSection = false
        for index in dashboards.indices {
            guard let saved = previousByID[dashboards[index].id] else { continue }
            if dashboards[index].sectionIssues[.releases] != nil {
                dashboards[index].releases = saved.releases
                dashboards[index].sectionIssues[.releases] = dashboards[index].sectionIssues[.releases]?
                    .fallingBackToCache(from: saved.sectionIssues[.releases]?.cachedAt ?? saved.fetchedAt)
                usedCachedSection = true
            }
            if dashboards[index].sectionIssues[.reviews] != nil {
                dashboards[index].reviews = saved.reviews
                dashboards[index].nextReviewsPage = saved.nextReviewsPage
                dashboards[index].sectionIssues[.reviews] = dashboards[index].sectionIssues[.reviews]?
                    .fallingBackToCache(from: saved.sectionIssues[.reviews]?.cachedAt ?? saved.fetchedAt)
                usedCachedSection = true
            }
            if dashboards[index].sectionIssues[.builds] != nil {
                dashboards[index].builds = saved.builds
                if dashboards[index].app.iconAsset == nil {
                    dashboards[index].app.iconAsset = saved.app.iconAsset
                }
                dashboards[index].sectionIssues[.builds] = dashboards[index].sectionIssues[.builds]?
                    .fallingBackToCache(from: saved.sectionIssues[.builds]?.cachedAt ?? saved.fetchedAt)
                usedCachedSection = true
            }
        }
        let collection = DashboardCollection(
            dashboards: dashboards,
            fetchedAt: usedCachedSection ? (previous?.fetchedAt ?? .now) : .now
        )

        for dashboard in dashboards {
            try Task.checkCancellation()
            if dashboard.sectionIssues[.releases] == nil {
                try await historyStore.record(dashboard.releases, appID: dashboard.id)
            }
            if dashboard.sectionIssues[.reviews] == nil
                || dashboard.sectionIssues[.reviews]?.usingCachedData == true {
                try await readStore.reconcile(appID: dashboard.id, reviews: dashboard.reviews)
            }
        }
        try Task.checkCancellation()
        try await cache.save(collection)
        return collection
    }

    func loadMoreReviews(for appID: String, in collection: DashboardCollection) async throws -> DashboardCollection {
        guard let dashboardIndex = collection.dashboards.firstIndex(where: { $0.id == appID }),
              let nextPage = collection.dashboards[dashboardIndex].nextReviewsPage else {
            return collection
        }
        let page = try await provider.fetchReviewsPage(at: nextPage)
        try Task.checkCancellation()
        var updated = collection
        let existingIDs = Set(updated.dashboards[dashboardIndex].reviews.map(\.id))
        updated.dashboards[dashboardIndex].reviews.append(
            contentsOf: page.reviews.filter { !existingIDs.contains($0.id) }
        )
        updated.dashboards[dashboardIndex].nextReviewsPage = page.nextPage
        // Later pages contain historical reviews. Discovering them must not turn them into new alerts.
        try await readStore.markAllRead(page.reviews)
        try Task.checkCancellation()
        try await cache.save(updated)
        return updated
    }
}
