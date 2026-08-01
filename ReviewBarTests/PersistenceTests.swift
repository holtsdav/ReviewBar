import Foundation
import Testing
@testable import ReviewBar

struct PersistenceTests {
    @Test("Snapshot cache round-trips protected Codable data")
    func snapshotCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(fileURL: url)
        let collection = DashboardCollection(dashboards: DemoFixtures.dashboards, fetchedAt: DemoFixtures.referenceDate)

        try await cache.save(collection)
        let loaded = try await cache.load()
        #expect(loaded == collection)
        try await cache.clear()
        #expect(try await cache.load() == nil)
    }

    @Test("First review sync creates a read baseline; later IDs are unread")
    func unreadBaseline() async throws {
        let store = ReviewReadStore()
        let existing = Array(DemoFixtures.dashboards[0].reviews.prefix(2))
        try await store.reconcile(appID: "app", reviews: existing)
        #expect(await store.unreadCount(in: existing) == 0)

        let withNew = existing + [DemoFixtures.dashboards[0].reviews[2]]
        #expect(await store.unreadCount(in: withNew) == 1)
        try await store.markRead(withNew[2].id)
        #expect(await store.unreadCount(in: withNew) == 0)
    }

    @Test("Review state is loaded lazily without losing persisted read IDs")
    func lazyReviewStateLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let review = DemoFixtures.dashboards[0].reviews[0]
        try await ReviewReadStore(fileURL: url).markRead(review.id)

        let reloaded = ReviewReadStore(fileURL: url)
        #expect(await reloaded.isUnread(review) == false)
    }

    @Test("Observed release history calculates waiting and review durations")
    func releaseStatistics() async throws {
        let store = ReleaseHistoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let release = DemoFixtures.dashboards[0].releases[0]

        try await store.record([copy(release, state: .waitingForReview)], appID: "app", at: base)
        try await store.record([copy(release, state: .inReview)], appID: "app", at: base.addingTimeInterval(3_600))
        try await store.record([copy(release, state: .readyForDistribution)], appID: "app", at: base.addingTimeInterval(10_800))

        let stats = await store.statistics(appID: "app")
        #expect(stats.averageWaiting == 3_600)
        #expect(stats.averageInReview == 7_200)
        #expect(stats.fastestApproval == 10_800)
        #expect(stats.completedReleaseCount == 1)
    }

    @Test("Release history is loaded lazily when first accessed")
    func lazyReleaseHistoryLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = DemoFixtures.dashboards[0].releases[0]
        try await ReleaseHistoryStore(fileURL: url).record([release], appID: "app")

        let reloaded = ReleaseHistoryStore(fileURL: url)
        #expect(await reloaded.observations(for: release.id).count == 1)
    }

    @Test("Rejected attempt is excluded while a later contiguous approval is counted")
    func resubmissionStatistics() async throws {
        let store = ReleaseHistoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let release = DemoFixtures.dashboards[0].releases[0]
        let states: [(ReleaseState, TimeInterval)] = [
            (.waitingForReview, 0), (.inReview, 100), (.rejected, 200),
            (.waitingForReview, 300), (.inReview, 500), (.readyForDistribution, 900)
        ]
        for (state, offset) in states {
            try await store.record([copy(release, state: state)], appID: "app", at: base.addingTimeInterval(offset))
        }
        let stats = await store.statistics(appID: "app")
        #expect(stats.completedReleaseCount == 1)
        #expect(stats.averageWaiting == 200)
        #expect(stats.averageInReview == 400)
        #expect(stats.fastestApproval == 600)
    }

    @Test("Failed review-state persistence does not mutate memory")
    func readPersistenceIsAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewReadStore(fileURL: directory.appending(path: "state.json"))
        let review = DemoFixtures.dashboards[0].reviews[0]
        await #expect(throws: (any Error).self) { try await store.markRead(review.id) }
        #expect(await store.isUnread(review))
    }

    @Test("Failed release-history persistence does not mutate memory")
    func historyPersistenceIsAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReleaseHistoryStore(fileURL: directory.appending(path: "history.json"))
        let release = DemoFixtures.dashboards[0].releases[0]
        await #expect(throws: (any Error).self) {
            try await store.record([release], appID: "app")
        }
        #expect(await store.observations(for: release.id).isEmpty)
    }

    @Test("Apple webhook timestamps replace same-state local observations and deduplicate delivery")
    func authoritativeReleaseHistory() async throws {
        let store = ReleaseHistoryStore()
        let release = DemoFixtures.dashboards[0].releases[0]
        let authoritativeTime = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record(
            [copy(release, state: .inReview)],
            appID: "app",
            at: authoritativeTime.addingTimeInterval(300)
        )
        try await store.recordAuthoritative(
            eventID: "event-1",
            appID: "app",
            releaseID: release.id,
            version: release.version,
            state: .inReview,
            occurredAt: authoritativeTime,
            source: .appleWebhook
        )
        try await store.recordAuthoritative(
            eventID: "event-1",
            appID: "app",
            releaseID: release.id,
            version: release.version,
            state: .inReview,
            occurredAt: authoritativeTime,
            source: .appleWebhook
        )

        let observations = await store.observations(for: release.id)
        #expect(observations.count == 1)
        #expect(observations[0].source == .appleWebhook)
        #expect(observations[0].observedAt == authoritativeTime)
        #expect(observations[0].externalEventID == "event-1")
    }

    @Test("Realtime state migrates old records and persists provisional cleanup identifiers")
    func realtimePendingCleanupPersistence() throws {
        let legacy = Data(#"{"id":"installation","token":"bearer","channels":[]}"#.utf8)
        let migrated = try JSONDecoder().decode(RealtimeInstallation.self, from: legacy)
        #expect(migrated.pendingCleanup.isEmpty)

        var current = migrated
        current.pendingCleanup = [RealtimePendingCleanup(
            id: "relay-channel",
            appID: "app",
            appName: "Universal App",
            webhookURL: URL(string: "https://relay.example/apple/relay-channel"),
            appleWebhookIDs: ["apple-webhook"]
        )]
        let roundTrip = try JSONDecoder().decode(
            RealtimeInstallation.self,
            from: JSONEncoder().encode(current)
        )
        #expect(roundTrip.pendingCleanup == current.pendingCleanup)
    }

    private func copy(_ release: AppRelease, state: ReleaseState) -> AppRelease {
        AppRelease(
            id: release.id,
            version: release.version,
            platform: release.platform,
            state: state,
            createdDate: release.createdDate,
            submittedDate: release.submittedDate,
            earliestReleaseDate: release.earliestReleaseDate,
            releaseType: release.releaseType,
            selectedBuildID: release.selectedBuildID,
            reviewSubmissionState: release.reviewSubmissionState
        )
    }
}
