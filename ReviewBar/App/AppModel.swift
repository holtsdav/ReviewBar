import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Session: Equatable {
        case starting
        case signedOut
        case ready
    }

    enum Source: Equatable {
        case live
        case demo
    }

    private(set) var session: Session
    private(set) var source: Source = .live
    private(set) var dashboards: [AppDashboard] = []
    private(set) var unreadReviewIDs: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var isLoadingMoreReviews = false
    private(set) var lastUpdated: Date?
    private(set) var showingCachedData = false
    var presentedError: AppError?

    private let credentialStore: any CredentialStoring
    private let cache: any SnapshotCaching
    private let historyStore: ReleaseHistoryStore
    private let readStore: ReviewReadStore
    private var repository: DashboardRepository?
    private var hasStarted = false

    init(
        session: Session = .starting,
        credentialStore: any CredentialStoring,
        cache: any SnapshotCaching,
        historyStore: ReleaseHistoryStore,
        readStore: ReviewReadStore
    ) {
        self.session = session
        self.credentialStore = credentialStore
        self.cache = cache
        self.historyStore = historyStore
        self.readStore = readStore
    }

    static func live() -> AppModel {
        AppModel(
            credentialStore: KeychainCredentialStore(),
            cache: SnapshotCache(),
            historyStore: .live(),
            readStore: .live()
        )
    }

    static func preview(session: Session = .ready) -> AppModel {
        let cache = MemorySnapshotCache(collection: DashboardCollection(
            dashboards: DemoFixtures.dashboards,
            fetchedAt: DemoFixtures.referenceDate
        ))
        let model = AppModel(
            session: session,
            credentialStore: MemoryCredentialStore(),
            cache: cache,
            historyStore: ReleaseHistoryStore(),
            readStore: ReviewReadStore(initiallyReadIDs: ["review-g-2", "review-g-3", "review-t-1"])
        )
        model.source = .demo
        model.dashboards = DemoFixtures.dashboards
        model.lastUpdated = DemoFixtures.referenceDate
        model.unreadReviewIDs = ["review-g-1"]
        model.repository = DashboardRepository(
            provider: DemoDataProvider(delay: .zero),
            cache: cache,
            historyStore: model.historyStore,
            readStore: model.readStore
        )
        return model
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-out") {
            session = .signedOut
            return
        }

        if ProcessInfo.processInfo.arguments.contains("-ui-testing-demo") {
            await enterDemo(persist: false)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-empty") {
            await enterDemo(persist: false, scenario: .empty)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-error") {
            await enterDemo(
                persist: false,
                scenario: .failure(AppError(
                    kind: .appleUnavailable,
                    message: "App Store Connect is temporarily unavailable."
                ))
            )
            return
        }

        if UserDefaults.standard.bool(forKey: "ReviewBar.demoMode") {
            await enterDemo(persist: false)
            return
        }

        do {
            guard let credential = try await credentialStore.load() else {
                session = .signedOut
                return
            }
            try await configureLiveRepository(credential: credential)
            session = .ready
            await loadCachedThenRefresh()
        } catch {
            session = .signedOut
            presentedError = AppError.map(error)
        }
    }

    func connect(_ credential: AppStoreConnectCredential) async {
        guard credential.isStructurallyValid else {
            presentedError = AppError(
                kind: .invalidCredentials,
                message: "Check the key ID, issuer ID, and imported .p8 private key."
            )
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await configureLiveRepository(credential: credential)
            guard let repository else { return }
            let collection = try await repository.refresh()
            try await credentialStore.save(credential)
            UserDefaults.standard.set(false, forKey: "ReviewBar.demoMode")
            source = .live
            session = .ready
            await apply(collection, cached: false)
        } catch {
            repository = nil
            presentedError = AppError.map(error)
        }
    }

    func enterDemo(persist: Bool = true, scenario: DemoDataProvider.Scenario = .standard) async {
        let demoCache = MemorySnapshotCache(collection: DashboardCollection(
            dashboards: scenario.isStandard ? DemoFixtures.dashboards : [],
            fetchedAt: .now
        ))
        repository = DashboardRepository(
            provider: DemoDataProvider(scenario: scenario),
            cache: demoCache,
            historyStore: historyStore,
            readStore: readStore
        )
        if persist { UserDefaults.standard.set(true, forKey: "ReviewBar.demoMode") }
        source = .demo
        session = .ready
        dashboards = scenario.isStandard ? DemoFixtures.dashboards : []
        lastUpdated = .now
        showingCachedData = false
        if case .failure(let error) = scenario {
            presentedError = error
        }
        let allReviewIDs = Set(DemoFixtures.dashboards.flatMap(\.reviews).map(\.id))
        do {
            try await readStore.configureDemo(
                appIDs: Set(DemoFixtures.dashboards.map(\.id)),
                readReviewIDs: allReviewIDs.subtracting(["review-g-1"])
            )
            for dashboard in DemoFixtures.dashboards {
                try await historyStore.record(dashboard.releases, appID: dashboard.id)
            }
        } catch {
            presentedError = AppError.map(error)
        }
        await updateUnreadState()
    }

    func refresh() async {
        guard let repository, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            await apply(try await repository.refresh(), cached: false)
        } catch is CancellationError {
            return
        } catch {
            showingCachedData = !dashboards.isEmpty
            presentedError = AppError.map(error)
        }
    }

    func loadMoreReviews(appID: String) async {
        guard let repository, !isLoadingMoreReviews else { return }
        let current = DashboardCollection(dashboards: dashboards, fetchedAt: lastUpdated ?? .now)
        isLoadingMoreReviews = true
        defer { isLoadingMoreReviews = false }
        do {
            await apply(try await repository.loadMoreReviews(for: appID, in: current), cached: showingCachedData)
        } catch is CancellationError {
            return
        } catch {
            presentedError = AppError.map(error)
        }
    }

    func markRead(_ review: CustomerReview) async {
        do {
            try await readStore.markRead(review.id)
            unreadReviewIDs.remove(review.id)
        } catch {
            presentedError = AppError.map(error)
        }
    }

    func markAllRead(in dashboard: AppDashboard) async {
        do {
            try await readStore.markAllRead(dashboard.reviews)
            unreadReviewIDs.subtract(dashboard.reviews.map(\.id))
        } catch {
            presentedError = AppError.map(error)
        }
    }

    func observations(for releaseID: String) async -> [ReleaseObservation] {
        await historyStore.observations(for: releaseID)
    }

    func statistics(for appID: String) async -> ReleaseStatistics {
        await historyStore.statistics(appID: appID)
    }

    func disconnect() async {
        do {
            try await credentialStore.delete()
            try await cache.clear()
            try await readStore.clear()
            try await historyStore.clear()
        } catch {
            presentedError = AppError.map(error)
        }
        UserDefaults.standard.set(false, forKey: "ReviewBar.demoMode")
        repository = nil
        dashboards = []
        unreadReviewIDs = []
        lastUpdated = nil
        showingCachedData = false
        source = .live
        session = .signedOut
    }

    private func loadCachedThenRefresh() async {
        if let repository {
            do {
                if let cached = try await repository.cached() {
                    await apply(cached, cached: true)
                }
            } catch {
                // A damaged cache should never prevent a live refresh.
            }
        }
        await refresh()
    }

    private func configureLiveRepository(credential: AppStoreConnectCredential) async throws {
        let provider = try AppStoreConnectDataProvider(credential: credential)
        repository = DashboardRepository(
            provider: provider,
            cache: cache,
            historyStore: historyStore,
            readStore: readStore
        )
    }

    private func apply(_ collection: DashboardCollection, cached: Bool) async {
        dashboards = collection.dashboards
        lastUpdated = collection.fetchedAt
        showingCachedData = cached
        await updateUnreadState()
    }

    private func updateUnreadState() async {
        let reviews = dashboards.flatMap(\.reviews)
        unreadReviewIDs = await readStore.unreadIDs(in: reviews)
    }
}

private extension DemoDataProvider.Scenario {
    var isStandard: Bool {
        if case .standard = self { return true }
        return false
    }
}
