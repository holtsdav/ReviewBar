import Foundation
import Testing
@testable import ReviewBar

struct DomainTests {
    @Test("Release states preserve future Apple values")
    func unknownReleaseState() {
        let state = ReleaseState(apiValue: "FUTURE_REVIEW_STATE")
        #expect(state.rawValue == "FUTURE_REVIEW_STATE")
        #expect(state.title == "Unknown (FUTURE_REVIEW_STATE)")
    }

    @Test("Every documented version state has an intentional title", arguments: [
        ("ACCEPTED", "Accepted"),
        ("DEVELOPER_REJECTED", "Developer Rejected"),
        ("IN_REVIEW", "In Review"),
        ("INVALID_BINARY", "Invalid Binary"),
        ("METADATA_REJECTED", "Metadata Rejected"),
        ("PENDING_APPLE_RELEASE", "Pending Apple Release"),
        ("PENDING_DEVELOPER_RELEASE", "Pending Developer Release"),
        ("PREPARE_FOR_SUBMISSION", "Prepare for Submission"),
        ("PROCESSING_FOR_DISTRIBUTION", "Processing for Distribution"),
        ("READY_FOR_DISTRIBUTION", "Ready for Distribution"),
        ("READY_FOR_REVIEW", "Ready for Review"),
        ("REJECTED", "Rejected"),
        ("REPLACED_WITH_NEW_VERSION", "Replaced by New Version"),
        ("WAITING_FOR_EXPORT_COMPLIANCE", "Waiting for Export Compliance"),
        ("WAITING_FOR_REVIEW", "Waiting for Review")
    ])
    func versionStateTitle(rawValue: String, expected: String) {
        #expect(ReleaseState(apiValue: rawValue).title == expected)
    }

    @Test("Review filters combine rating, territory, version, and oldest sort")
    func reviewFiltering() {
        let filter = ReviewFilter(
            ratings: [5],
            territory: "USA",
            appVersion: "1.3",
            sort: .oldest
        )
        let results = filter.apply(to: DemoFixtures.dashboards[0].reviews)
        #expect(results.map(\.id) == ["review-g-1"])
    }

    @Test("Review search, unread, and response filters compose")
    func reviewWorkflowFiltering() {
        let filter = ReviewFilter(
            query: "exactly",
            unreadOnly: true,
            response: .withoutResponse
        )
        let results = filter.apply(
            to: DemoFixtures.dashboards[0].reviews,
            unreadIDs: ["review-g-1", "review-g-2"]
        )

        #expect(results.map(\.id) == ["review-g-1"])
        #expect(filter.activeCriteriaCount == 3)
    }

    @Test("Review filtering cooperatively observes cancellation")
    func reviewFilteringCancellation() {
        let reviews = Array(repeating: DemoFixtures.dashboards[0].reviews, count: 100).flatMap { $0 }
        var cancellationChecks = 0

        #expect(throws: CancellationError.self) {
            try ReviewFilter().apply(to: reviews) {
                cancellationChecks += 1
                if cancellationChecks == 2 { throw CancellationError() }
            }
        }
        #expect(cancellationChecks == 2)
    }

    @Test("Dashboard attention includes failed builds and release failures")
    func dashboardAttention() throws {
        let failedBuildDashboard = try #require(
            DemoFixtures.dashboards.first { dashboard in
                dashboard.builds.contains { $0.processingState == .failed }
            }
        )
        #expect(failedBuildDashboard.requiresAttention)
        #expect(DemoFixtures.dashboards[0].requiresAttention == false)
    }

    @Test("Expired builds stay distinct from successful processing")
    func expiredBuildPrecedence() {
        let build = DemoFixtures.dashboards[1].builds.first { $0.expired }
        #expect(build?.processingState == .valid)
        #expect(build?.expired == true)
    }

    @Test("Demo includes realistic TestFlight metadata")
    func demoTestFlightMetadata() throws {
        let build = try #require(DemoFixtures.dashboards[0].builds.first { $0.buildNumber == "47" })
        #expect(build.audienceType == "APP_STORE_ELIGIBLE")
        #expect(build.internalBetaState == "IN_BETA_TESTING")
        #expect(build.externalBetaState == "IN_BETA_TESTING")
        #expect(build.betaReviewState == "APPROVED")
        #expect(build.selectedForAppStoreVersion == "1.4")
    }

    @Test("macOS-only apps remain visible")
    func macOSOnlyApp() throws {
        let dashboard = try #require(DemoFixtures.dashboards.first { $0.app.name == "Trail Notes" })
        #expect(dashboard.availablePlatforms == [.macOS])
        #expect(dashboard.currentRelease(in: .macOS)?.platform == .macOS)
        #expect(dashboard.latestBuild(in: .macOS)?.platform == .macOS)
    }

    @Test("iOS-only apps remain visible")
    func iOSOnlyApp() throws {
        let dashboard = try #require(DemoFixtures.dashboards.first { $0.app.name == "Quiet Budget" })
        #expect(dashboard.availablePlatforms == [.visionOS])
        let livingRoom = try #require(DemoFixtures.dashboards.first { $0.app.name == "Living Room Scores" })
        #expect(livingRoom.availablePlatforms == [.tvOS])
        let iOS = AppDashboard(
            app: dashboard.app,
            releases: [AppRelease(
                id: "ios-only",
                version: "1.0",
                platform: .iOS,
                state: .readyForDistribution,
                createdDate: .now,
                submittedDate: nil,
                earliestReleaseDate: nil,
                releaseType: nil
            )],
            reviews: [],
            builds: [],
            fetchedAt: .now
        )
        #expect(iOS.availablePlatforms == [.iOS])
    }

    @Test("Multi-platform apps retain independent current releases and builds")
    func multiPlatformApp() throws {
        let dashboard = try #require(DemoFixtures.dashboards.first { $0.app.name == "Glassdays" })
        #expect(dashboard.availablePlatforms == [.iOS, .macOS])
        #expect(dashboard.currentRelease(in: .iOS)?.version == "1.4")
        #expect(dashboard.currentRelease(in: .macOS)?.version == "2.0")
        #expect(dashboard.latestBuild(in: .iOS)?.platform == .iOS)
        #expect(dashboard.latestBuild(in: .macOS)?.platform == .macOS)
    }

    @Test("All current App Store Connect platform values map intentionally", arguments: [
        ("IOS", AppRelease.Platform.iOS),
        ("MAC_OS", .macOS),
        ("TV_OS", .tvOS),
        ("VISION_OS", .visionOS)
    ])
    func platformMapping(apiValue: String, platform: AppRelease.Platform) {
        #expect(AppRelease.Platform(apiValue: apiValue) == platform)
    }

    @Test("Accepted remains the current unreleased version")
    func acceptedCurrentRelease() {
        let original = DemoFixtures.dashboards[0]
        let live = original.releases[1]
        let accepted = AppRelease(
            id: "accepted",
            version: "1.5",
            platform: .iOS,
            state: .accepted,
            createdDate: .now,
            submittedDate: .now,
            earliestReleaseDate: nil,
            releaseType: nil,
            selectedBuildID: nil,
            reviewSubmissionState: "COMPLETE"
        )
        let dashboard = AppDashboard(
            app: original.app,
            releases: [accepted, live],
            reviews: [],
            builds: [],
            nextReviewsPage: nil,
            fetchedAt: .now
        )
        #expect(dashboard.currentRelease?.id == accepted.id)
        #expect(dashboard.distributionReadyRelease?.id == live.id)
    }

    @Test("Developer response publication states stay distinct")
    func responseStates() {
        #expect(DeveloperResponseState.published.title == "Developer response published")
        #expect(DeveloperResponseState.pendingPublish.title.contains("awaiting"))
        #expect(DeveloperResponseState(apiValue: "FUTURE_STATE").rawValue == "FUTURE_STATE")
    }
}
