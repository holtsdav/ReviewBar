import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

@MainActor
struct AppModelTests {
    @Test("Favorite apps and app-list choices persist locally")
    func appPreferencesPersistence() {
        let suiteName = "ReviewBarTests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defer { defaults?.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        preferences.toggleFavorite(appID: "app-1")
        preferences.appListSort = .favoritesFirst
        preferences.appActivityFilter = .needsAttention

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.favoriteAppIDs == ["app-1"])
        #expect(restored.appListSort == .favoritesFirst)
        #expect(restored.appActivityFilter == .needsAttention)
    }

    @Test("Preview fixture data is isolated from live stores")
    func previewDataIsolation() async throws {
        let liveReads = ReviewReadStore()
        let liveHistory = ReleaseHistoryStore()
        let firstReview = DemoFixtures.dashboards[0].reviews[0]
        try await liveReads.reconcile(appID: "live-app", reviews: [firstReview])
        let sentinel = DashboardCollection(
            dashboards: [DemoFixtures.dashboards[1]],
            fetchedAt: DemoFixtures.referenceDate
        )
        let liveCache = MemorySnapshotCache(collection: sentinel)
        let model = AppModel(
            session: .signedOut,
            credentialStore: MemoryCredentialStore(),
            cache: liveCache,
            historyStore: liveHistory,
            readStore: liveReads
        )

        let preview = AppModel.preview()
        #expect(preview.dashboards == DemoFixtures.dashboards)
        #expect(await liveCache.load() == sentinel)
        #expect(await liveReads.unreadCount(in: DemoFixtures.dashboards[0].reviews) == 2)
        #expect(await liveHistory.observations(for: DemoFixtures.dashboards[0].releases[0].id).isEmpty)
        #expect(model.session == .signedOut)
        #expect(await liveCache.load() == sentinel)
    }

    @Test("Failed Keychain deletion keeps the active session")
    func failedCredentialDeletion() async {
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            scope: .individual
        )
        let credentials = DeleteFailingCredentialStore(credential: credential)
        let model = AppModel(
            session: .ready,
            credentialStore: credentials,
            cache: MemorySnapshotCache(),
            historyStore: ReleaseHistoryStore(),
            readStore: ReviewReadStore()
        )

        #expect(await model.disconnect() == false)
        #expect(model.session == .ready)
        #expect(model.presentedError?.kind == .secureStorage)
        #expect(await credentials.load() != nil)
    }
}

private actor DeleteFailingCredentialStore: CredentialStoring {
    private var credential: AppStoreConnectCredential?

    init(credential: AppStoreConnectCredential) {
        self.credential = credential
    }

    func load() -> AppStoreConnectCredential? { credential }
    func save(_ credential: AppStoreConnectCredential) { self.credential = credential }
    func delete() throws {
        throw AppError(kind: .secureStorage, message: "Simulated Keychain failure")
    }
}
