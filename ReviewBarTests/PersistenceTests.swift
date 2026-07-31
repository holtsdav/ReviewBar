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
