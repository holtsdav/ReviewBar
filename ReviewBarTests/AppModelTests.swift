import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

@MainActor
struct AppModelTests {
    @Test("Demo mode leaves live cache, unread state, and release history untouched")
    func demoStorageIsolation() async throws {
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

        await model.enterDemo(persist: false)
        #expect(model.source == .demo)
        #expect(await liveCache.load() == sentinel)
        #expect(await liveReads.unreadCount(in: DemoFixtures.dashboards[0].reviews) == 2)
        #expect(await liveHistory.observations(for: DemoFixtures.dashboards[0].releases[0].id).isEmpty)

        await model.exitDemo()
        #expect(model.source == .live)
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
