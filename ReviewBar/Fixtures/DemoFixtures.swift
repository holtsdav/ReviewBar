import Foundation

enum DemoFixtures {
    static let referenceDate = ISO8601DateFormatter().date(from: "2026-07-31T12:00:00Z") ?? .distantPast

    static let glassdays = DeveloperApp(
        id: "app-glassdays",
        name: "Glassdays",
        bundleID: "com.example.glassdays",
        sku: "GLASSDAYS-001",
        primaryLocale: "en-US"
    )

    static let trailNotes = DeveloperApp(
        id: "app-trailnotes",
        name: "Trail Notes",
        bundleID: "com.example.trailnotes",
        sku: "TRAILNOTES-001",
        primaryLocale: "en-US"
    )

    static let quietBudget = DeveloperApp(
        id: "app-quietbudget",
        name: "Quiet Budget",
        bundleID: "com.example.quietbudget",
        sku: "QUIETBUDGET-001",
        primaryLocale: "de-DE"
    )

    static let dashboards: [AppDashboard] = [
        AppDashboard(
            app: glassdays,
            releases: [
                AppRelease(
                    id: "release-glassdays-1.4",
                    version: "1.4",
                    platform: .iOS,
                    state: .inReview,
                    createdDate: referenceDate.addingTimeInterval(-8 * 86_400),
                    submittedDate: referenceDate.addingTimeInterval(-6 * 3_600),
                    earliestReleaseDate: nil,
                    releaseType: "MANUAL"
                ),
                AppRelease(
                    id: "release-glassdays-1.3",
                    version: "1.3",
                    platform: .iOS,
                    state: .readyForDistribution,
                    createdDate: referenceDate.addingTimeInterval(-50 * 86_400),
                    submittedDate: referenceDate.addingTimeInterval(-45 * 86_400),
                    earliestReleaseDate: referenceDate.addingTimeInterval(-44 * 86_400),
                    releaseType: "AFTER_APPROVAL"
                )
            ],
            reviews: [
                CustomerReview(
                    id: "review-g-1",
                    rating: 5,
                    title: "Exactly what I wanted",
                    body: "The latest update is quick, thoughtful, and doesn’t get in the way. The new weekly view is especially useful.",
                    reviewerNickname: "PixelNomad",
                    territory: "USA",
                    createdDate: referenceDate.addingTimeInterval(-42 * 60),
                    appVersion: "1.3",
                    hasDeveloperResponse: false
                ),
                CustomerReview(
                    id: "review-g-2",
                    rating: 3,
                    title: "Promising, but one issue",
                    body: "Beautiful app. Export sometimes takes two attempts on my phone, so I hope that can be fixed soon.",
                    reviewerNickname: "NorthStar87",
                    territory: "CAN",
                    createdDate: referenceDate.addingTimeInterval(-3 * 86_400),
                    appVersion: "1.3",
                    hasDeveloperResponse: true
                ),
                CustomerReview(
                    id: "review-g-3",
                    rating: 4,
                    title: "Sehr übersichtlich",
                    body: "Funktioniert zuverlässig und sieht sehr gut aus. Ein Widget wäre noch hilfreich.",
                    reviewerNickname: "Morgenlicht",
                    territory: "DEU",
                    createdDate: referenceDate.addingTimeInterval(-12 * 86_400),
                    appVersion: "1.2",
                    hasDeveloperResponse: false
                )
            ],
            builds: [
                BuildInfo(
                    id: "build-g-48",
                    buildNumber: "48",
                    version: "1.4",
                    platform: .iOS,
                    uploadedDate: referenceDate.addingTimeInterval(-18 * 60),
                    expirationDate: referenceDate.addingTimeInterval(89 * 86_400),
                    expired: false,
                    processingState: .processing,
                    minimumOSVersion: "18.0"
                ),
                BuildInfo(
                    id: "build-g-47",
                    buildNumber: "47",
                    version: "1.4",
                    platform: .iOS,
                    uploadedDate: referenceDate.addingTimeInterval(-7 * 3_600),
                    expirationDate: referenceDate.addingTimeInterval(88 * 86_400),
                    expired: false,
                    processingState: .valid,
                    minimumOSVersion: "18.0"
                )
            ],
            nextReviewsPage: URL(string: "reviewbar-demo://reviews/glassdays/2"),
            fetchedAt: referenceDate
        ),
        AppDashboard(
            app: trailNotes,
            releases: [
                AppRelease(
                    id: "release-trailnotes-2.1",
                    version: "2.1",
                    platform: .iOS,
                    state: .waitingForReview,
                    createdDate: referenceDate.addingTimeInterval(-5 * 86_400),
                    submittedDate: referenceDate.addingTimeInterval(-22 * 3_600),
                    earliestReleaseDate: nil,
                    releaseType: "AFTER_APPROVAL"
                )
            ],
            reviews: [
                CustomerReview(
                    id: "review-t-1",
                    rating: 2,
                    title: "Sync needs work",
                    body: "I like the concept, but two hikes disappeared after reinstalling. Please make the sync status clearer.",
                    reviewerNickname: "ridgewalker",
                    territory: "GBR",
                    createdDate: referenceDate.addingTimeInterval(-9 * 3_600),
                    appVersion: "2.0",
                    hasDeveloperResponse: false
                )
            ],
            builds: [
                BuildInfo(
                    id: "build-t-103",
                    buildNumber: "103",
                    version: "2.1",
                    platform: .iOS,
                    uploadedDate: referenceDate.addingTimeInterval(-25 * 3_600),
                    expirationDate: referenceDate.addingTimeInterval(70 * 86_400),
                    expired: false,
                    processingState: .valid,
                    minimumOSVersion: "17.0"
                ),
                BuildInfo(
                    id: "build-t-87",
                    buildNumber: "87",
                    version: "2.0",
                    platform: .iOS,
                    uploadedDate: referenceDate.addingTimeInterval(-120 * 86_400),
                    expirationDate: referenceDate.addingTimeInterval(-30 * 86_400),
                    expired: true,
                    processingState: .valid,
                    minimumOSVersion: "17.0"
                )
            ],
            nextReviewsPage: nil,
            fetchedAt: referenceDate
        ),
        AppDashboard(
            app: quietBudget,
            releases: [],
            reviews: [],
            builds: [
                BuildInfo(
                    id: "build-q-12",
                    buildNumber: "12",
                    version: "1.0",
                    platform: .iOS,
                    uploadedDate: referenceDate.addingTimeInterval(-2 * 86_400),
                    expirationDate: nil,
                    expired: false,
                    processingState: .failed,
                    minimumOSVersion: "18.0"
                )
            ],
            nextReviewsPage: nil,
            fetchedAt: referenceDate
        )
    ]

    static let olderReviews = [
        CustomerReview(
            id: "review-g-4",
            rating: 1,
            title: "Lost my settings",
            body: "After the previous update my custom settings reset. Support was kind, but this should not happen.",
            reviewerNickname: "orbit-17",
            territory: "AUS",
            createdDate: referenceDate.addingTimeInterval(-40 * 86_400),
            appVersion: "1.1",
            hasDeveloperResponse: true
        )
    ]
}

