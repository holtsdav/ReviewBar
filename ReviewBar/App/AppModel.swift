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
    private(set) var lastRefreshIssue: AppError?
    private(set) var analyticsStates: [String: AnalyticsLoadState] = [:]
    var presentedError: AppError?

    private let credentialStore: any CredentialStoring
    private let cache: any SnapshotCaching
    private let liveHistoryStore: ReleaseHistoryStore
    private let liveReadStore: ReviewReadStore
    private let liveAnalyticsCache: any AnalyticsCaching
    private var historyStore: ReleaseHistoryStore
    private var readStore: ReviewReadStore
    private var analyticsCache: any AnalyticsCaching
    private var repository: DashboardRepository?
    private var analyticsRepository: AnalyticsRepository?
    private var hasStarted = false
    private var dataTask: Task<DashboardCollection, Error>?
    private var operationID: UUID?
    private var sessionGeneration = 0

    init(
        session: Session = .starting,
        credentialStore: any CredentialStoring,
        cache: any SnapshotCaching,
        historyStore: ReleaseHistoryStore,
        readStore: ReviewReadStore,
        analyticsCache: any AnalyticsCaching = MemoryAnalyticsCache()
    ) {
        self.session = session
        self.credentialStore = credentialStore
        self.cache = cache
        liveHistoryStore = historyStore
        liveReadStore = readStore
        liveAnalyticsCache = analyticsCache
        self.historyStore = historyStore
        self.readStore = readStore
        self.analyticsCache = analyticsCache
    }

    static func live() -> AppModel {
        AppModel(
            credentialStore: KeychainCredentialStore(),
            cache: SnapshotCache(),
            historyStore: .live(),
            readStore: .live(),
            analyticsCache: AnalyticsCache()
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
        let analyticsCache = MemoryAnalyticsCache(datasets: DemoFixtures.dashboards.map { DemoFixtures.analytics(appID: $0.id) })
        model.analyticsCache = analyticsCache
        model.analyticsRepository = AnalyticsRepository(provider: DemoAnalyticsProvider(), cache: analyticsCache)
        model.analyticsStates = Dictionary(uniqueKeysWithValues: DemoFixtures.dashboards.map {
            ($0.id, .available(DemoFixtures.analytics(appID: $0.id)))
        })
        return model
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        if UserDefaults.standard.bool(forKey: "ReviewBar.pendingLocalCleanup") {
            let cleared = await clearLiveLocalData()
            UserDefaults.standard.set(!cleared, forKey: "ReviewBar.pendingLocalCleanup")
            if !cleared {
                presentedError = AppError(
                    kind: .secureStorage,
                    message: "ReviewBar could not finish erasing previously cached local data. It will retry the next time the app opens."
                )
            }
        }

        #if DEBUG
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
        #endif

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
            lastRefreshIssue = nil
            await apply(collection, cached: false)
        } catch {
            let mapped = AppError.map(error)
            repository = nil
            dashboards = []
            unreadReviewIDs = []
            lastUpdated = nil
            let cleared = await clearLiveLocalData()
            UserDefaults.standard.set(!cleared, forKey: "ReviewBar.pendingLocalCleanup")
            presentedError = mapped
        }
    }

    func enterDemo(persist: Bool = true, scenario: DemoDataProvider.Scenario = .standard) async {
        sessionGeneration += 1
        dataTask?.cancel()
        dataTask = nil
        operationID = nil
        isRefreshing = false
        isLoadingMoreReviews = false
        let demoHistoryStore = ReleaseHistoryStore()
        let demoReadStore = ReviewReadStore()
        let demoAnalyticsCache = MemoryAnalyticsCache()
        historyStore = demoHistoryStore
        readStore = demoReadStore
        analyticsCache = demoAnalyticsCache
        let demoCache = MemorySnapshotCache(collection: DashboardCollection(
            dashboards: scenario.isStandard ? DemoFixtures.dashboards : [],
            fetchedAt: .now
        ))
        repository = DashboardRepository(
            provider: DemoDataProvider(scenario: scenario),
            cache: demoCache,
            historyStore: demoHistoryStore,
            readStore: demoReadStore
        )
        analyticsRepository = AnalyticsRepository(provider: DemoAnalyticsProvider(), cache: demoAnalyticsCache)
        if persist { UserDefaults.standard.set(true, forKey: "ReviewBar.demoMode") }
        source = .demo
        session = .ready
        dashboards = scenario.isStandard ? DemoFixtures.dashboards : []
        lastUpdated = .now
        showingCachedData = false
        lastRefreshIssue = nil
        analyticsStates = [:]
        if case .failure(let error) = scenario {
            presentedError = error
            lastRefreshIssue = error
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

    func analyticsState(for appID: String) -> AnalyticsLoadState {
        analyticsStates[appID] ?? .idle
    }

    func cachedDataSizeInBytes() async -> Int64 {
        let snapshotBytes = await cache.sizeInBytes()
        let analyticsBytes = await analyticsCache.sizeInBytes()
        let iconBytes = await AppIconCache.shared.sizeInBytes()
        return snapshotBytes + analyticsBytes + iconBytes
    }

    func clearCachedData() async {
        do {
            try await cache.clear()
            if let analyticsRepository {
                try await analyticsRepository.clear()
            } else {
                try await analyticsCache.clear()
            }
            try await AppIconCache.shared.clear()
            analyticsStates = [:]
        } catch {
            presentedError = AppError(
                kind: .secureStorage,
                message: "ReviewBar couldn't completely clear its local cache. Try again after restarting the app."
            )
        }
    }

    /// Makes cached Analytics visible without waiting for report discovery or downloads.
    func prepareAnalytics(appID: String) async {
        guard analyticsStates[appID] == nil || analyticsStates[appID] == .idle,
              let analyticsRepository else { return }
        if let cached = try? await analyticsRepository.cached(appID: appID) {
            analyticsStates[appID] = .available(cached)
        }
    }

    func loadAnalytics(appID: String, force: Bool = false) async {
        guard let analyticsRepository else { return }
        let current = analyticsStates[appID] ?? .idle
        if case .loading = current { return }
        if !force, case .available(let dataset) = current,
           Date.now.timeIntervalSince(dataset.fetchedAt) < 15 * 60 { return }

        let cached: AnalyticsDataset?
        if let currentDataset = current.cachedDataset {
            cached = currentDataset
        } else {
            cached = try? await analyticsRepository.cached(appID: appID)
        }
        analyticsStates[appID] = .loading(cached: cached)
        do {
            switch try await analyticsRepository.refresh(appID: appID) {
            case .dataset(let dataset): analyticsStates[appID] = .available(dataset)
            case .notEnabled: analyticsStates[appID] = .notEnabled
            case .generating: analyticsStates[appID] = .generating
            case .stoppedDueToInactivity: analyticsStates[appID] = .stoppedDueToInactivity
            }
        } catch is CancellationError {
            analyticsStates[appID] = cached.map(AnalyticsLoadState.available) ?? .idle
        } catch {
            let mapped = AppError.map(error)
            if mapped.kind == .insufficientPermission {
                analyticsStates[appID] = .permissionRequired(
                    "This key can't read Analytics Reports. Use an Admin, Sales and Reports, or Finance API key with access to this app."
                )
            } else {
                analyticsStates[appID] = .failed(message: mapped.message, cached: cached)
            }
        }
    }

    func enableAnalytics(appID: String) async {
        guard let analyticsRepository else { return }
        analyticsStates[appID] = .loading(cached: nil)
        do {
            try await analyticsRepository.createOngoingRequest(appID: appID)
            analyticsStates[appID] = .generating
        } catch {
            let mapped = AppError.map(error)
            if mapped.kind == .insufficientPermission {
                analyticsStates[appID] = .permissionRequired(
                    "An Admin API key is required to create the initial ongoing Analytics Report request for this app."
                )
            } else {
                analyticsStates[appID] = .failed(message: mapped.message, cached: nil)
            }
        }
    }

    func refresh() async {
        guard let repository, dataTask == nil else { return }
        let identifier = UUID()
        let generation = sessionGeneration
        isRefreshing = true
        let task = Task { try await repository.refresh() }
        dataTask = task
        operationID = identifier
        do {
            let collection = try await task.value
            guard operationID == identifier,
                  sessionGeneration == generation,
                  session == .ready else { return }
            lastRefreshIssue = nil
            await apply(
                collection,
                cached: false,
                expectedGeneration: generation,
                expectedOperationID: identifier
            )
        } catch is CancellationError {
            // Cancellation is an expected part of disconnecting or replacing a session.
        } catch {
            guard operationID == identifier, sessionGeneration == generation else { return }
            let mapped = AppError.map(error)
            showingCachedData = !dashboards.isEmpty
            lastRefreshIssue = mapped
            presentedError = mapped
        }
        if operationID == identifier {
            dataTask = nil
            operationID = nil
            isRefreshing = false
        }
    }

    func loadMoreReviews(appID: String) async {
        guard let repository, dataTask == nil else { return }
        let current = DashboardCollection(dashboards: dashboards, fetchedAt: lastUpdated ?? .now)
        let identifier = UUID()
        let generation = sessionGeneration
        isLoadingMoreReviews = true
        let task = Task { try await repository.loadMoreReviews(for: appID, in: current) }
        dataTask = task
        operationID = identifier
        do {
            let collection = try await task.value
            guard operationID == identifier,
                  sessionGeneration == generation,
                  session == .ready else { return }
            await apply(
                collection,
                cached: showingCachedData,
                expectedGeneration: generation,
                expectedOperationID: identifier
            )
        } catch is CancellationError {
            // Cancellation is an expected part of disconnecting or replacing a session.
        } catch {
            guard operationID == identifier, sessionGeneration == generation else { return }
            let mapped = AppError.map(error)
            lastRefreshIssue = mapped
            presentedError = mapped
        }
        if operationID == identifier {
            dataTask = nil
            operationID = nil
            isLoadingMoreReviews = false
        }
    }

    func refreshIfStale() async {
        guard session == .ready, dataTask == nil else { return }
        guard let lastUpdated else {
            await refresh()
            return
        }
        if Date.now.timeIntervalSince(lastUpdated) >= 5 * 60 {
            await refresh()
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

    @discardableResult
    func disconnect() async -> Bool {
        if source == .demo {
            await exitDemo()
            return true
        }
        sessionGeneration += 1
        let pendingTask = dataTask
        pendingTask?.cancel()
        dataTask = nil
        operationID = nil
        isRefreshing = false
        isLoadingMoreReviews = false
        if let pendingTask {
            _ = try? await pendingTask.value
        }

        do {
            try await credentialStore.delete()
            guard try await credentialStore.load() == nil else {
                throw AppError(
                    kind: .secureStorage,
                    message: "ReviewBar could not verify that the credential was removed. The connection remains active."
                )
            }
        } catch {
            let mapped = AppError.map(error)
            presentedError = mapped.kind == .secureStorage ? mapped : AppError(
                kind: .secureStorage,
                message: "ReviewBar could not remove the credential from the Keychain. The connection remains active."
            )
            return false
        }

        // Drop the in-memory signer immediately after the Keychain item is gone.
        repository = nil
        analyticsRepository = nil
        let cleanupSucceeded = await clearLiveLocalData()
        UserDefaults.standard.set(!cleanupSucceeded, forKey: "ReviewBar.pendingLocalCleanup")

        UserDefaults.standard.set(false, forKey: "ReviewBar.demoMode")
        dashboards = []
        analyticsStates = [:]
        unreadReviewIDs = []
        lastUpdated = nil
        showingCachedData = false
        lastRefreshIssue = nil
        source = .live
        session = .signedOut
        if !cleanupSucceeded {
            presentedError = AppError(
                kind: .secureStorage,
                message: "The credential was removed, but some cached local data could not be erased. ReviewBar will retry automatically the next time it opens; deleting the app also removes its local data."
            )
        }
        return true
    }

    func exitDemo() async {
        sessionGeneration += 1
        let pendingTask = dataTask
        pendingTask?.cancel()
        dataTask = nil
        operationID = nil
        isRefreshing = false
        isLoadingMoreReviews = false
        if let pendingTask { _ = try? await pendingTask.value }

        UserDefaults.standard.set(false, forKey: "ReviewBar.demoMode")
        repository = nil
        analyticsRepository = nil
        dashboards = []
        analyticsStates = [:]
        unreadReviewIDs = []
        lastUpdated = nil
        showingCachedData = false
        lastRefreshIssue = nil
        source = .live
        historyStore = liveHistoryStore
        readStore = liveReadStore
        analyticsCache = liveAnalyticsCache

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
        let analyticsProvider = try AppStoreConnectAnalyticsProvider(credential: credential)
        historyStore = liveHistoryStore
        readStore = liveReadStore
        analyticsCache = liveAnalyticsCache
        repository = DashboardRepository(
            provider: provider,
            cache: cache,
            historyStore: liveHistoryStore,
            readStore: liveReadStore
        )
        analyticsRepository = AnalyticsRepository(provider: analyticsProvider, cache: liveAnalyticsCache)
    }

    private func clearLiveLocalData() async -> Bool {
        var succeeded = true
        do { try await cache.clear() } catch { succeeded = false }
        do { try await liveReadStore.clear() } catch { succeeded = false }
        do { try await liveHistoryStore.clear() } catch { succeeded = false }
        do { try await liveAnalyticsCache.clear() } catch { succeeded = false }
        do { try await AppIconCache.shared.clear() } catch { succeeded = false }
        return succeeded
    }

    private func apply(
        _ collection: DashboardCollection,
        cached: Bool,
        expectedGeneration: Int? = nil,
        expectedOperationID: UUID? = nil
    ) async {
        let stateStore = readStore
        let unread = await stateStore.unreadIDs(in: collection.dashboards.flatMap(\.reviews))
        if let expectedGeneration, expectedGeneration != sessionGeneration { return }
        if let expectedOperationID, expectedOperationID != operationID { return }
        guard session == .ready else { return }
        dashboards = collection.dashboards
        lastUpdated = collection.fetchedAt
        showingCachedData = cached || collection.hasStaleSections
        unreadReviewIDs = unread
    }

    private func updateUnreadState() async {
        let generation = sessionGeneration
        let reviews = dashboards.flatMap(\.reviews)
        let stateStore = readStore
        let unread = await stateStore.unreadIDs(in: reviews)
        guard generation == sessionGeneration else { return }
        unreadReviewIDs = unread
    }
}

private extension DemoDataProvider.Scenario {
    var isStandard: Bool {
        if case .standard = self { return true }
        return false
    }
}
