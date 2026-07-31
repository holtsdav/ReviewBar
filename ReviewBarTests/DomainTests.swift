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
}
