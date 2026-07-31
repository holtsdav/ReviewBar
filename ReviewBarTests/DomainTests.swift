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

    @Test("Only iOS builds are kept for the iPhone dashboard")
    func iOSBuildFiltering() {
        let ios = DemoFixtures.dashboards[0].builds[0]
        let mac = BuildInfo(
            id: "mac-build",
            buildNumber: "9",
            version: "2.0",
            platform: .macOS,
            uploadedDate: .now,
            expirationDate: nil,
            expired: false,
            processingState: .valid,
            minimumOSVersion: "15.0"
        )
        #expect(AppStoreConnectDataProvider.iOSBuilds([mac, ios]).map(\.id) == [ios.id])
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
