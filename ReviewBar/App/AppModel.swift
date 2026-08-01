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

    private(set) var session: Session
    private(set) var dashboards: [AppDashboard] = []
    private(set) var unreadReviewIDs: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var isLoadingMoreReviews = false
    private(set) var lastUpdated: Date?
    private(set) var showingCachedData = false
    private(set) var lastRefreshIssue: AppError?
    private(set) var analyticsStates: [String: AnalyticsLoadState] = [:]
    private(set) var realtimeInstallation: RealtimeInstallation?
    private(set) var realtimeSetupState: RealtimeSetupState = .loading
    var presentedError: AppError?

    private let credentialStore: any CredentialStoring
    private let cache: any SnapshotCaching
    private let liveHistoryStore: ReleaseHistoryStore
    private let liveReadStore: ReviewReadStore
    private let liveAnalyticsCache: any AnalyticsCaching
    private let realtimeStateStore: any RealtimeStateStoring
    private let relayConfiguration: NotificationRelayConfiguration
    private var historyStore: ReleaseHistoryStore
    private var readStore: ReviewReadStore
    private var analyticsCache: any AnalyticsCaching
    private var repository: DashboardRepository?
    private var analyticsRepository: AnalyticsRepository?
    private var hasStarted = false
    private var dataTask: Task<DashboardCollection, Error>?
    private var operationID: UUID?
    private var sessionGeneration = 0
    @ObservationIgnored private var realtimeOperationTask: Task<Void, Never>?
    private var realtimeOperationID: UUID?
    private var realtimeRevision = 0
    private var realtimeTeardownInProgress = false

    init(
        session: Session = .starting,
        credentialStore: any CredentialStoring,
        cache: any SnapshotCaching,
        historyStore: ReleaseHistoryStore,
        readStore: ReviewReadStore,
        analyticsCache: any AnalyticsCaching = MemoryAnalyticsCache(),
        realtimeStateStore: any RealtimeStateStoring = MemoryRealtimeStateStore(),
        relayConfiguration: NotificationRelayConfiguration = NotificationRelayConfiguration(baseURL: nil)
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
        self.realtimeStateStore = realtimeStateStore
        self.relayConfiguration = relayConfiguration
    }

    static func live() -> AppModel {
        AppModel(
            credentialStore: KeychainCredentialStore(),
            cache: SnapshotCache(),
            historyStore: .live(),
            readStore: .live(),
            analyticsCache: AnalyticsCache(),
            realtimeStateStore: KeychainRealtimeStateStore(),
            relayConfiguration: .bundled
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
        var canPrepareRealtimeState = true
        if UserDefaults.standard.bool(forKey: "ReviewBar.pendingRealtimeLocalCleanup") {
            do {
                try await realtimeStateStore.delete()
                UserDefaults.standard.set(false, forKey: "ReviewBar.pendingRealtimeLocalCleanup")
            } catch {
                canPrepareRealtimeState = false
                presentedError = AppError(
                    kind: .secureStorage,
                    message: "ReviewBar couldn't finish removing an inactive notification registration from Keychain. It will retry next launch."
                )
            }
        }
        if canPrepareRealtimeState {
            await prepareRealtimeState()
        } else {
            realtimeSetupState = .failed("An inactive local notification registration is awaiting secure cleanup.")
        }

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
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("ReviewBar.platform.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-out") {
            session = .signedOut
            return
        }

        if ProcessInfo.processInfo.arguments.contains("-ui-testing-fixture") {
            await loadUITestFixture()
            if let appID = dashboards.first?.id {
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-analytics-permission") {
                    analyticsStates[appID] = .permissionRequired(
                        "An Admin API key is required to create the initial ongoing Analytics Report request for this app.",
                        cached: nil
                    )
                } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-analytics-empty") {
                    analyticsStates[appID] = .available(AnalyticsDataset(
                        appID: appID,
                        requestID: "empty-fixture",
                        accessType: "ONGOING",
                        series: [],
                        fetchedAt: .now,
                        warnings: []
                    ))
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-empty") {
            await loadUITestFixture(scenario: .empty)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-error") {
            await loadUITestFixture(
                scenario: .failure(AppError(
                    kind: .appleUnavailable,
                    message: "App Store Connect is temporarily unavailable."
                ))
            )
            return
        }
        #endif

        // Remove the legacy local-data flag so upgraded installs always use
        // the authenticated App Store Connect path.
        UserDefaults.standard.removeObject(forKey: "ReviewBar.demoMode")

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
            session = .ready
            lastRefreshIssue = nil
            await apply(collection, cached: false)
        } catch {
            let mapped = AppError.map(error)
            if let analyticsRepository { try? await analyticsRepository.clear() }
            repository = nil
            analyticsRepository = nil
            dashboards = []
            unreadReviewIDs = []
            lastUpdated = nil
            let cleared = await clearLiveLocalData()
            UserDefaults.standard.set(!cleared, forKey: "ReviewBar.pendingLocalCleanup")
            presentedError = mapped
        }
    }

    #if DEBUG
    private func loadUITestFixture(scenario: DemoDataProvider.Scenario = .standard) async {
        guard !realtimeTeardownInProgress else { return }
        realtimeTeardownInProgress = true
        defer { realtimeTeardownInProgress = false }
        // UI fixtures are ephemeral and never persisted. They are available
        // only to automated tests and SwiftUI previews, not to product users.
        await waitForRealtimeOperation()
        sessionGeneration += 1
        realtimeRevision += 1
        if let analyticsRepository { await analyticsRepository.cancelInFlight() }
        dataTask?.cancel()
        dataTask = nil
        operationID = nil
        isRefreshing = false
        isLoadingMoreReviews = false
        let fixtureHistoryStore = ReleaseHistoryStore()
        let fixtureReadStore = ReviewReadStore()
        let fixtureAnalyticsCache = MemoryAnalyticsCache()
        historyStore = fixtureHistoryStore
        readStore = fixtureReadStore
        analyticsCache = fixtureAnalyticsCache
        let fixtureCache = MemorySnapshotCache(collection: DashboardCollection(
            dashboards: scenario.isStandard ? DemoFixtures.dashboards : [],
            fetchedAt: .now
        ))
        repository = DashboardRepository(
            provider: DemoDataProvider(scenario: scenario),
            cache: fixtureCache,
            historyStore: fixtureHistoryStore,
            readStore: fixtureReadStore
        )
        analyticsRepository = AnalyticsRepository(provider: DemoAnalyticsProvider(), cache: fixtureAnalyticsCache)
        realtimeSetupState = .unavailable("Real-time updates are unavailable for local test fixtures.")
        session = .ready
        dashboards = scenario.isStandard ? DemoFixtures.dashboards : []
        lastUpdated = .now
        showingCachedData = false
        lastRefreshIssue = nil
        analyticsStates = [:]
        if scenario.isStandard {
            for dashboard in DemoFixtures.dashboards {
                let dataset = DemoFixtures.analytics(appID: dashboard.id)
                await fixtureAnalyticsCache.save(dataset)
                analyticsStates[dashboard.id] = .available(dataset)
            }
        }
        if case .failure(let error) = scenario {
            presentedError = error
            lastRefreshIssue = error
        }
        let allReviewIDs = Set(DemoFixtures.dashboards.flatMap(\.reviews).map(\.id))
        do {
            try await readStore.configureFixture(
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
    #endif

    var realtimeRelayIsConfigured: Bool { effectiveRealtimeRelayURL != nil }

    func realtimeIsEnabled(appID: String) -> Bool {
        realtimeInstallation?.channels.contains { $0.appID == appID } == true
    }

    func prepareRealtimeState(allowDuringTeardown: Bool = false) async {
        guard (allowDuringTeardown || !realtimeTeardownInProgress),
              realtimeOperationTask == nil else { return }
        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPrepareRealtimeState()
        }
        realtimeOperationID = identifier
        realtimeOperationTask = task
        await task.value
        if realtimeOperationID == identifier {
            realtimeOperationTask = nil
            realtimeOperationID = nil
        }
    }

    private func performPrepareRealtimeState() async {
        do {
            var saved = try await realtimeStateStore.load()
            if saved?.relayBaseURL == nil, let baseURL = relayConfiguration.baseURL {
                saved?.relayBaseURL = baseURL
                if let saved { try await realtimeStateStore.save(saved) }
            }
            realtimeInstallation = saved
            if saved?.channels.isEmpty == true, saved?.pendingCleanup.isEmpty == true {
                await removeEmptyRealtimeInstallationIfPossible()
                saved = realtimeInstallation
                if saved?.channels.isEmpty == true, saved?.pendingCleanup.isEmpty == true {
                    realtimeSetupState = .failed(
                        "An incomplete device registration is awaiting relay cleanup. ReviewBar retained its secure bearer and will retry."
                    )
                    return
                }
            }
            if saved?.pendingCleanup.isEmpty == false {
                await retryPendingRealtimeCleanup()
                saved = realtimeInstallation
                if saved?.pendingCleanup.isEmpty == false {
                    realtimeSetupState = .failed(
                        "A partial notification setup is awaiting cleanup. ReviewBar retained its secure identifiers and will retry when this screen opens."
                    )
                    return
                }
            }
            guard effectiveRealtimeRelayURL != nil else {
                realtimeSetupState = .unavailable("Deploy and configure the optional ReviewBar notification relay to enable this feature.")
                return
            }
            realtimeSetupState = .ready
            if let realtimeInstallation {
                Task { [weak self] in
                    await self?.refreshRealtimeDeviceToken(for: realtimeInstallation)
                }
            }
        } catch {
            realtimeSetupState = .failed(AppError.map(error).message)
        }
    }

    func enableRealtime(
        appID: String,
        eventTypes: [AppStoreConnectWebhookEventType] = [
            .appVersionStateUpdated,
            .buildUploadStateUpdated,
            .externalBuildStateUpdated
        ]
    ) async {
        guard !realtimeTeardownInProgress, realtimeOperationTask == nil,
              session == .ready else { return }
        if realtimeInstallation?.pendingCleanup.contains(where: { $0.appID == appID }) == true {
            await prepareRealtimeState()
        }
        guard !realtimeTeardownInProgress, realtimeOperationTask == nil,
              !realtimeIsEnabled(appID: appID),
              session == .ready,
              realtimeInstallation?.pendingCleanup.contains(where: { $0.appID == appID }) != true,
              !eventTypes.isEmpty, effectiveRealtimeRelayURL != nil else { return }
        let identifier = UUID()
        let generation = sessionGeneration
        let revision = realtimeRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performEnableRealtime(
                appID: appID,
                eventTypes: eventTypes,
                expectedGeneration: generation,
                expectedRevision: revision
            )
        }
        realtimeOperationID = identifier
        realtimeOperationTask = task
        await task.value
        if realtimeOperationID == identifier {
            realtimeOperationTask = nil
            realtimeOperationID = nil
        }
    }

    private func performEnableRealtime(
        appID: String,
        eventTypes: [AppStoreConnectWebhookEventType],
        expectedGeneration: Int,
        expectedRevision: Int
    ) async {
        guard let app = dashboards.first(where: { $0.id == appID })?.app,
              let baseURL = effectiveRealtimeRelayURL else { return }
        realtimeSetupState = .configuring(appID: appID)
        do {
            try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            guard let credential = try await credentialStore.load() else {
                throw AppError(kind: .noCredentials, message: "Reconnect App Store Connect before enabling real-time updates.")
            }
            try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            let deviceToken = try await PushRegistrationCenter.shared.requestDeviceToken().lowercaseHexString
            try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            let relay = try NotificationRelayClient(baseURL: baseURL)
            var installation: RealtimeInstallation
            let savedInstallation: RealtimeInstallation?
            if let realtimeInstallation {
                savedInstallation = realtimeInstallation
            } else {
                savedInstallation = try await realtimeStateStore.load()
            }
            if let existing = savedInstallation {
                installation = existing
                try await relay.rotateDeviceToken(deviceToken, environment: Self.apnsEnvironment, installation: existing)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            } else {
                installation = try await relay.register(apnsToken: deviceToken, environment: Self.apnsEnvironment)
                // Retain the newly issued bearer in memory before persistence so
                // a Keychain error can still be compensated during this session.
                realtimeInstallation = installation
                do {
                    try await realtimeStateStore.save(installation)
                    try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
                } catch {
                    await rollbackRealtimeCreation(relay: relay, installation: installation)
                    throw error
                }
            }

            let relayChannel = try await relay.createChannel(
                app: app,
                eventTypes: eventTypes,
                installation: installation
            )
            var pendingCleanup = RealtimePendingCleanup(
                id: relayChannel.channelID,
                appID: app.id,
                appName: app.name,
                webhookURL: relayChannel.webhookURL,
                appleWebhookIDs: []
            )
            installation.pendingCleanup.append(pendingCleanup)
            realtimeInstallation = installation
            do {
                try await realtimeStateStore.save(installation)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            } catch {
                let cleaned = await rollbackPendingRealtimeCleanup(
                    pendingCleanup,
                    relay: relay,
                    installation: installation,
                    appleCreationWasRejected: true
                )
                if !cleaned { throw pendingRealtimeCleanupError() }
                throw error
            }
            let apple = try AppStoreConnectWebhookProvider(credential: credential)
            let webhook: WebhookAPIResource
            do {
                webhook = try await apple.create(
                    appID: app.id,
                    appName: app.name,
                    url: relayChannel.webhookURL,
                    secret: relayChannel.secret,
                    eventTypes: eventTypes
                )
            } catch {
                let authoritativeRejection = (error as? AppError)?.requestWasRejected == true
                let cleaned = await rollbackPendingRealtimeCleanup(
                    pendingCleanup,
                    relay: relay,
                    installation: installation,
                    apple: apple,
                    appleCreationWasRejected: authoritativeRejection
                )
                if !cleaned { throw pendingRealtimeCleanupError() }
                throw error
            }
            pendingCleanup.appleWebhookIDs = [webhook.id]
            if let index = installation.pendingCleanup.firstIndex(where: { $0.id == pendingCleanup.id }) {
                installation.pendingCleanup[index] = pendingCleanup
            }
            realtimeInstallation = installation
            do {
                try await realtimeStateStore.save(installation)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            } catch {
                let cleaned = await rollbackPendingRealtimeCleanup(
                    pendingCleanup,
                    relay: relay,
                    installation: installation,
                    apple: apple
                )
                if !cleaned { throw pendingRealtimeCleanupError() }
                throw error
            }
            do {
                try await relay.confirm(
                    channelID: relayChannel.channelID,
                    webhookID: webhook.id,
                    installation: installation
                )
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            } catch {
                let cleaned = await rollbackPendingRealtimeCleanup(
                    pendingCleanup,
                    relay: relay,
                    installation: installation,
                    apple: apple
                )
                if !cleaned { throw pendingRealtimeCleanupError() }
                throw error
            }
            let localChannel = RealtimeChannel(
                id: relayChannel.channelID,
                appID: app.id,
                appName: app.name,
                appleWebhookID: webhook.id,
                eventTypes: eventTypes
            )
            installation.pendingCleanup.removeAll { $0.id == pendingCleanup.id }
            installation.channels.append(localChannel)
            do {
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
                try await realtimeStateStore.save(installation)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            } catch {
                var compensatingInstallation = installation
                compensatingInstallation.channels.removeAll { $0.id == relayChannel.channelID }
                if !compensatingInstallation.pendingCleanup.contains(where: { $0.id == pendingCleanup.id }) {
                    compensatingInstallation.pendingCleanup.append(pendingCleanup)
                }
                realtimeInstallation = compensatingInstallation
                try? await realtimeStateStore.save(compensatingInstallation)
                let cleaned = await rollbackPendingRealtimeCleanup(
                    pendingCleanup,
                    relay: relay,
                    installation: compensatingInstallation,
                    apple: apple
                )
                if !cleaned { throw pendingRealtimeCleanupError() }
                throw error
            }
            realtimeInstallation = installation
            realtimeRevision += 1
            realtimeSetupState = .ready
            try? await apple.ping(webhookID: webhook.id)
        } catch is CancellationError {
            await removeEmptyRealtimeInstallationIfPossible()
        } catch {
            await removeEmptyRealtimeInstallationIfPossible()
            let mapped = AppError.map(error)
            let message = mapped.kind == .insufficientPermission
                ? "Apple requires the Account Holder, Admin, or App Manager role to create webhooks for this app."
                : mapped.message
            realtimeSetupState = .failed(message)
        }
    }

    func disableRealtime(appID: String) async {
        guard !realtimeTeardownInProgress, realtimeOperationTask == nil,
              session == .ready,
              realtimeInstallation?.channels.contains(where: { $0.appID == appID }) == true else { return }
        let identifier = UUID()
        let generation = sessionGeneration
        let revision = realtimeRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDisableRealtime(
                appID: appID,
                expectedGeneration: generation,
                expectedRevision: revision
            )
        }
        realtimeOperationID = identifier
        realtimeOperationTask = task
        await task.value
        if realtimeOperationID == identifier {
            realtimeOperationTask = nil
            realtimeOperationID = nil
        }
    }

    private func performDisableRealtime(
        appID: String,
        expectedGeneration: Int,
        expectedRevision: Int
    ) async {
        guard var installation = realtimeInstallation,
              let channel = installation.channels.first(where: { $0.appID == appID }),
              let baseURL = installation.relayBaseURL ?? relayConfiguration.baseURL else { return }
        realtimeSetupState = .configuring(appID: appID)
        var appleCleanupFailed = false
        let savedCredential = try? await credentialStore.load()
        guard (try? validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)) != nil else { return }
        if let credential = savedCredential,
           let apple = try? AppStoreConnectWebhookProvider(credential: credential) {
            do { try await apple.delete(webhookID: channel.appleWebhookID) }
            catch { appleCleanupFailed = true }
        } else {
            appleCleanupFailed = true
        }
        do {
            try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            let relay = try NotificationRelayClient(baseURL: baseURL)
            try await relay.deleteChannel(channelID: channel.id, installation: installation)
            try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            installation.channels.removeAll { $0.id == channel.id }
            if installation.channels.isEmpty {
                try await relay.deleteInstallation(installation)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
                try await realtimeStateStore.delete()
                realtimeInstallation = nil
            } else {
                try await realtimeStateStore.save(installation)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
                realtimeInstallation = installation
            }
            realtimeRevision += 1
            realtimeSetupState = appleCleanupFailed
                ? .failed("Relay delivery is off, but ReviewBar couldn't remove Apple's webhook. Delete the remaining ReviewBar webhook in App Store Connect.")
                : .ready
        } catch is CancellationError {
            // A disconnect or source transition owns cleanup from this point.
        } catch {
            realtimeSetupState = .failed("ReviewBar couldn't stop relay delivery. Try again before removing the App Store Connect key.")
        }
    }

    func syncRealtimeEvents() async {
        guard !realtimeTeardownInProgress, realtimeOperationTask == nil,
              session == .ready, realtimeInstallation != nil else { return }
        let identifier = UUID()
        let generation = sessionGeneration
        let revision = realtimeRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSyncRealtimeEvents(expectedGeneration: generation, expectedRevision: revision)
        }
        realtimeOperationID = identifier
        realtimeOperationTask = task
        await task.value
        if realtimeOperationID == identifier {
            realtimeOperationTask = nil
            realtimeOperationID = nil
        }
    }

    private func performSyncRealtimeEvents(expectedGeneration: Int, expectedRevision: Int) async {
        guard var installation = realtimeInstallation,
              let baseURL = installation.relayBaseURL ?? relayConfiguration.baseURL else { return }
        do {
            let relay = try NotificationRelayClient(baseURL: baseURL)
            let batch = try await relay.events(installation: installation)
            try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            for event in batch.events where event.eventType == "appStoreVersionAppVersionStateUpdated" {
                guard let releaseID = event.instanceID,
                      let stateValue = event.newState,
                      let occurredAt = event.authoritativeTimestamp,
                      let channel = installation.channels.first(where: { $0.id == event.channelID }) else { continue }
                let release = dashboards
                    .first(where: { $0.id == channel.appID })?
                    .releases.first(where: { $0.id == releaseID })
                try await historyStore.recordAuthoritative(
                    eventID: event.eventID,
                    appID: channel.appID,
                    releaseID: releaseID,
                    version: release?.version ?? "",
                    state: ReleaseState(apiValue: stateValue),
                    occurredAt: occurredAt,
                    source: .appleWebhook
                )
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
            }
            if let latest = batch.events.map(\.receivedAt).max() {
                installation.lastEventSync = latest
            }
            if let checkpointCursor = batch.checkpointCursor {
                installation.lastEventCursor = checkpointCursor
            }
            if batch.checkpointCursor != nil || !batch.events.isEmpty {
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
                try await realtimeStateStore.save(installation)
                try validateRealtimeOperation(generation: expectedGeneration, revision: expectedRevision)
                realtimeInstallation = installation
                realtimeRevision += 1
            }
        } catch is CancellationError {
            // Source changes and configuration mutations deliberately cancel sync.
        } catch {
            // Event-feed synchronization supplements the normal App Store Connect
            // refresh and must never make the core dashboard unavailable.
        }
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private func validateRealtimeOperation(generation: Int, revision: Int) throws {
        try Task.checkCancellation()
        guard generation == sessionGeneration,
              revision == realtimeRevision else { throw CancellationError() }
    }

    private func waitForRealtimeOperation() async {
        let identifier = realtimeOperationID
        let task = realtimeOperationTask
        if let task { await task.value }
        if realtimeOperationID == identifier {
            realtimeOperationTask = nil
            realtimeOperationID = nil
        }
    }

    private func rollbackRealtimeCreation(
        relay: NotificationRelayClient,
        installation: RealtimeInstallation,
        channelID: String? = nil,
        apple: AppStoreConnectWebhookProvider? = nil,
        webhookID: String? = nil
    ) async {
        // Compensation must run in a fresh task: the setup task is commonly
        // cancelled by disconnect transitions, and URLSession correctly
        // refuses new work from an already-cancelled task.
        await Task.detached(priority: .utility) {
            if let apple, let webhookID { try? await apple.delete(webhookID: webhookID) }
            if let channelID {
                try? await relay.deleteChannel(channelID: channelID, installation: installation)
            } else {
                try? await relay.deleteInstallation(installation)
            }
        }.value
    }

    private func rollbackPendingRealtimeCleanup(
        _ pending: RealtimePendingCleanup,
        relay: NotificationRelayClient,
        installation: RealtimeInstallation,
        apple: AppStoreConnectWebhookProvider? = nil,
        appleCreationWasRejected: Bool = false
    ) async -> Bool {
        let result = await Task.detached(priority: .utility) { () -> (apple: Bool, relay: Bool, webhookIDs: [String]) in
            let appleRemoved: Bool
            var webhookIDs = Set(pending.appleWebhookIDs)
            let reconciliationSucceeded: Bool
            if appleCreationWasRejected {
                reconciliationSucceeded = true
            } else if let apple, let webhookURL = pending.webhookURL {
                do {
                    let discovered = try await apple.matchingWebhooks(appID: pending.appID, url: webhookURL)
                    webhookIDs.formUnion(discovered.map(\.id))
                    reconciliationSucceeded = true
                } catch {
                    reconciliationSucceeded = false
                }
            } else {
                reconciliationSucceeded = pending.webhookURL == nil && webhookIDs.isEmpty
            }
            var allAppleDeletesSucceeded = true
            if !webhookIDs.isEmpty, let apple {
                for webhookID in webhookIDs {
                    do { try await apple.delete(webhookID: webhookID) }
                    catch { allAppleDeletesSucceeded = false }
                }
            } else if !webhookIDs.isEmpty {
                allAppleDeletesSucceeded = false
            }
            appleRemoved = reconciliationSucceeded && allAppleDeletesSucceeded
            let relayRemoved: Bool
            do {
                try await relay.deleteChannel(channelID: pending.id, installation: installation)
                relayRemoved = true
            } catch {
                relayRemoved = false
            }
            return (appleRemoved, relayRemoved, Array(webhookIDs).sorted())
        }.value

        var updated = installation
        if result.apple && result.relay {
            updated.pendingCleanup.removeAll { $0.id == pending.id }
        } else {
            var retained = pending
            if let index = updated.pendingCleanup.firstIndex(where: { $0.id == pending.id }) {
                retained.appleWebhookIDs = Array(Set(
                    updated.pendingCleanup[index].appleWebhookIDs + pending.appleWebhookIDs + result.webhookIDs
                )).sorted()
                updated.pendingCleanup[index] = retained
            } else {
                retained.appleWebhookIDs = Array(Set(retained.appleWebhookIDs + result.webhookIDs)).sorted()
                updated.pendingCleanup.append(retained)
            }
        }
        realtimeInstallation = updated
        try? await realtimeStateStore.save(updated)
        return result.apple && result.relay
    }

    private func pendingRealtimeCleanupError() -> AppError {
        AppError(
            kind: .other,
            message: "Setup didn't finish, and ReviewBar is retaining a secure cleanup record. Keep the connection and retry cleanup from Real-Time Updates."
        )
    }

    private func retryPendingRealtimeCleanup() async {
        guard var installation = realtimeInstallation,
              let baseURL = installation.relayBaseURL ?? relayConfiguration.baseURL,
              let relay = try? NotificationRelayClient(baseURL: baseURL) else { return }
        let credential = try? await credentialStore.load()
        let apple = credential.flatMap { try? AppStoreConnectWebhookProvider(credential: $0) }
        for pending in installation.pendingCleanup {
            _ = await rollbackPendingRealtimeCleanup(
                pending,
                relay: relay,
                installation: installation,
                apple: apple
            )
            installation = realtimeInstallation ?? installation
        }
        await removeEmptyRealtimeInstallationIfPossible()
    }

    private func refreshRealtimeDeviceToken(for installation: RealtimeInstallation) async {
        do {
            let token = try await PushRegistrationCenter.shared.registerForDeviceToken().lowercaseHexString
            guard realtimeInstallation?.id == installation.id,
                  let baseURL = installation.relayBaseURL ?? relayConfiguration.baseURL else { return }
            let relay = try NotificationRelayClient(baseURL: baseURL)
            try await relay.rotateDeviceToken(token, environment: Self.apnsEnvironment, installation: installation)
        } catch {
            guard realtimeInstallation?.id == installation.id else { return }
            realtimeSetupState = .failed("ReviewBar couldn't refresh this device's push registration. Open Real-Time Updates to try again.")
        }
    }

    func analyticsState(for appID: String) -> AnalyticsLoadState {
        analyticsStates[appID] ?? .idle
    }

    func cachedDataSizeInBytes() async -> Int64 {
        let snapshotBytes = await cache.sizeInBytes()
        let analyticsBytes = if let analyticsRepository {
            await analyticsRepository.sizeInBytes()
        } else {
            await analyticsCache.sizeInBytes()
        }
        let iconBytes = await AppIconCache.shared.sizeInBytes()
        return snapshotBytes + analyticsBytes + iconBytes
    }

    func clearCachedData() async {
        let dashboardTask = dataTask
        dashboardTask?.cancel()
        dataTask = nil
        operationID = nil
        isRefreshing = false
        isLoadingMoreReviews = false
        if let dashboardTask { _ = try? await dashboardTask.value }
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
        let generation = sessionGeneration
        if let cached = try? await analyticsRepository.cached(appID: appID) {
            guard generation == sessionGeneration,
                  session == .ready,
                  self.analyticsRepository === analyticsRepository else { return }
            analyticsStates[appID] = .available(cached)
        }
    }

    func loadAnalytics(appID: String, force: Bool = false) async {
        guard let analyticsRepository else { return }
        let generation = sessionGeneration
        let current = analyticsStates[appID] ?? .idle
        if case .loading = current { return }
        if !force {
            switch current {
            case .notEnabled, .generating, .stoppedDueToInactivity, .permissionRequired:
                return
            default:
                break
            }
        }
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
            let result = try await analyticsRepository.refresh(appID: appID)
            guard generation == sessionGeneration, session == .ready else { return }
            switch result {
            case .dataset(let dataset): analyticsStates[appID] = .available(dataset)
            case .notEnabled: analyticsStates[appID] = .notEnabled(cached: cached)
            case .generating: analyticsStates[appID] = .generating(cached: cached)
            case .stoppedDueToInactivity: analyticsStates[appID] = .stoppedDueToInactivity(cached: cached)
            }
        } catch is CancellationError {
            guard generation == sessionGeneration, session == .ready else { return }
            analyticsStates[appID] = cached.map(AnalyticsLoadState.available) ?? .idle
        } catch {
            guard generation == sessionGeneration, session == .ready else { return }
            let mapped = AppError.map(error)
            if mapped.kind == .insufficientPermission {
                analyticsStates[appID] = .permissionRequired(
                    "This key can't read Analytics Reports. Use an Admin, Sales and Reports, or Finance API key with access to this app.",
                    cached: cached
                )
            } else {
                analyticsStates[appID] = .failed(message: mapped.message, cached: cached)
            }
        }
    }

    func enableAnalytics(appID: String) async {
        guard let analyticsRepository else { return }
        let generation = sessionGeneration
        let cached = analyticsStates[appID]?.cachedDataset
        analyticsStates[appID] = .loading(cached: cached)
        do {
            try await analyticsRepository.createOngoingRequest(appID: appID)
            guard generation == sessionGeneration, session == .ready else { return }
            analyticsStates[appID] = .generating(cached: cached)
        } catch {
            guard generation == sessionGeneration, session == .ready else { return }
            let mapped = AppError.map(error)
            if mapped.kind == .insufficientPermission {
                analyticsStates[appID] = .permissionRequired(
                    "An Admin API key is required to create the initial ongoing Analytics Report request for this app.",
                    cached: cached
                )
            } else {
                analyticsStates[appID] = .failed(message: mapped.message, cached: cached)
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
            await syncRealtimeEvents()
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
        guard !realtimeTeardownInProgress else { return false }
        realtimeTeardownInProgress = true
        defer { realtimeTeardownInProgress = false }
        await waitForRealtimeOperation()
        sessionGeneration += 1
        realtimeRevision += 1
        if let analyticsRepository { await analyticsRepository.cancelInFlight() }
        let pendingTask = dataTask
        pendingTask?.cancel()
        dataTask = nil
        operationID = nil
        isRefreshing = false
        isLoadingMoreReviews = false
        if let pendingTask {
            _ = try? await pendingTask.value
        }

        let realtimeCleanup = await removeRealtimeConfigurationBeforeDisconnect()
        guard realtimeCleanup.relayStopped else {
            presentedError = AppError(
                kind: .other,
                message: "ReviewBar couldn't safely reconcile and stop real-time notification delivery. The connection remains active so you can retry without losing the secure cleanup record."
            )
            return false
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
        var analyticsCleanupSucceeded = true
        if let analyticsRepository {
            do { try await analyticsRepository.clear() }
            catch { analyticsCleanupSucceeded = false }
        }
        repository = nil
        analyticsRepository = nil
        let cleanupSucceeded = await clearLiveLocalData() && analyticsCleanupSucceeded
        UserDefaults.standard.set(!cleanupSucceeded, forKey: "ReviewBar.pendingLocalCleanup")

        dashboards = []
        analyticsStates = [:]
        unreadReviewIDs = []
        lastUpdated = nil
        showingCachedData = false
        lastRefreshIssue = nil
        session = .signedOut
        realtimeInstallation = nil
        realtimeSetupState = relayConfiguration.baseURL == nil
            ? .unavailable("The optional notification relay isn't configured in this build.")
            : .ready
        if !cleanupSucceeded {
            presentedError = AppError(
                kind: .secureStorage,
                message: "The credential was removed, but some cached local data could not be erased. ReviewBar will retry automatically the next time it opens; deleting the app also removes its local data."
            )
        } else if !realtimeCleanup.appleWebhooksRemoved {
            presentedError = AppError(
                kind: .other,
                message: "The connection was removed and relay delivery was muted, but ReviewBar couldn't delete every Apple webhook. Remove any remaining ReviewBar webhook in App Store Connect."
            )
        }
        return true
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

    private struct RealtimeDisconnectCleanup {
        let relayStopped: Bool
        let appleWebhooksRemoved: Bool
    }

    private func removeRealtimeConfigurationBeforeDisconnect() async -> RealtimeDisconnectCleanup {
        let savedInstallation: RealtimeInstallation?
        if let realtimeInstallation {
            savedInstallation = realtimeInstallation
        } else {
            savedInstallation = try? await realtimeStateStore.load()
        }
        guard var installation = savedInstallation else {
            return RealtimeDisconnectCleanup(relayStopped: true, appleWebhooksRemoved: true)
        }
        var appleWebhooksRemoved = true
        let credential = try? await credentialStore.load()
        let apple = credential.flatMap { try? AppStoreConnectWebhookProvider(credential: $0) }
        let relayURL = installation.relayBaseURL ?? relayConfiguration.baseURL
        let relay = relayURL.flatMap { try? NotificationRelayClient(baseURL: $0) }

        // Resolve ambiguous Apple create responses before removing either the
        // relay mapping or the credential. Losing the callback URL here would
        // make an Apple-side webhook impossible to identify precisely later.
        for index in installation.pendingCleanup.indices {
            let pending = installation.pendingCleanup[index]
            guard let webhookURL = pending.webhookURL, let apple else {
                if pending.appleWebhookIDs.isEmpty {
                    realtimeInstallation = installation
                    return RealtimeDisconnectCleanup(relayStopped: false, appleWebhooksRemoved: false)
                }
                continue
            }
            do {
                let discovered = try await apple.matchingWebhooks(appID: pending.appID, url: webhookURL)
                installation.pendingCleanup[index].appleWebhookIDs = Array(Set(
                    pending.appleWebhookIDs + discovered.map(\.id)
                )).sorted()
            } catch {
                realtimeInstallation = installation
                return RealtimeDisconnectCleanup(relayStopped: false, appleWebhooksRemoved: false)
            }
        }
        do {
            try await realtimeStateStore.save(installation)
            realtimeInstallation = installation
        } catch {
            realtimeInstallation = installation
            return RealtimeDisconnectCleanup(relayStopped: false, appleWebhooksRemoved: false)
        }
        for channel in installation.channels {
            if let apple {
                do { try await apple.delete(webhookID: channel.appleWebhookID) }
                catch { appleWebhooksRemoved = false }
            } else {
                appleWebhooksRemoved = false
            }
        }
        for pending in installation.pendingCleanup {
            for webhookID in pending.appleWebhookIDs {
                if let apple {
                    do { try await apple.delete(webhookID: webhookID) }
                    catch { appleWebhooksRemoved = false }
                } else {
                    appleWebhooksRemoved = false
                }
            }
        }

        guard let relay else {
            // Preserve the installation bearer in Keychain. Disconnect must not
            // remove the only authority capable of retrying relay deletion.
            realtimeInstallation = installation
            return RealtimeDisconnectCleanup(relayStopped: false, appleWebhooksRemoved: appleWebhooksRemoved)
        }

        do {
            // Installation deletion cascades channels and is the authoritative
            // relay-side cleanup. Individual DELETEs make the operation easier
            // to observe and remain idempotent when retried.
            for channel in installation.channels {
                try? await relay.deleteChannel(channelID: channel.id, installation: installation)
            }
            for pending in installation.pendingCleanup {
                try? await relay.deleteChannel(channelID: pending.id, installation: installation)
            }
            try await relay.deleteInstallation(installation)
        } catch {
            realtimeInstallation = installation
            return RealtimeDisconnectCleanup(relayStopped: false, appleWebhooksRemoved: appleWebhooksRemoved)
        }

        do {
            try await realtimeStateStore.delete()
            UserDefaults.standard.set(false, forKey: "ReviewBar.pendingRealtimeLocalCleanup")
        } catch {
            // The remote registration is already gone, so retaining this local
            // encrypted tombstone cannot cause delivery. Retry erasure at launch.
            UserDefaults.standard.set(true, forKey: "ReviewBar.pendingRealtimeLocalCleanup")
        }
        realtimeInstallation = nil
        realtimeRevision += 1
        return RealtimeDisconnectCleanup(relayStopped: true, appleWebhooksRemoved: appleWebhooksRemoved)
    }

    private var effectiveRealtimeRelayURL: URL? {
        realtimeInstallation?.relayBaseURL ?? relayConfiguration.baseURL
    }

    private func removeEmptyRealtimeInstallationIfPossible() async {
        let savedInstallation: RealtimeInstallation?
        if let realtimeInstallation {
            savedInstallation = realtimeInstallation
        } else {
            savedInstallation = try? await realtimeStateStore.load()
        }
        guard let installation = savedInstallation,
              installation.channels.isEmpty,
              installation.pendingCleanup.isEmpty,
              let baseURL = installation.relayBaseURL ?? relayConfiguration.baseURL,
              let relay = try? NotificationRelayClient(baseURL: baseURL) else { return }
        do {
            try await relay.deleteInstallation(installation)
            try await realtimeStateStore.delete()
            realtimeInstallation = nil
        } catch {
            // Keep the bearer in Keychain so cleanup can be retried later.
            realtimeInstallation = installation
        }
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
