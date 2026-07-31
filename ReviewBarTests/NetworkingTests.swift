import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

struct NetworkingTests {
    @Test("HTTP errors map to distinct user-facing categories", arguments: [
        (401, AppError.Kind.invalidCredentials),
        (403, AppError.Kind.insufficientPermission),
        (429, AppError.Kind.rateLimited(retryAfter: 30)),
        (503, AppError.Kind.appleUnavailable)
    ])
    func errorMapping(status: Int, expectedKind: AppError.Kind) {
        let data = Data(#"{"errors":[{"code":"RATE_LIMIT_EXCEEDED"}]}"#.utf8)
        let mapped = AppleHTTPErrorMapper.map(
            statusCode: status,
            data: data,
            retryAfterHeader: status == 429 ? "30" : nil
        )
        #expect(mapped.kind == expectedKind)
    }

    @Test("Transport rejects hostile pagination hosts before creating a request")
    func hostilePaginationHost() async throws {
        let key = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: key.pemRepresentation,
            scope: .individual
        )
        let transport = AppleAPITransport(signer: try JWTGenerator(credential: credential))
        let url = try #require(URL(string: "https://attacker.example/v1/apps?cursor=stolen"))

        do {
            _ = try await transport.get(url)
            Issue.record("Expected the hostile host to be rejected")
        } catch let error as AppError {
            #expect(error.kind == .malformedResponse)
        }
    }

    @Test("Repository pagination deduplicates IDs, saves the page, and keeps history read")
    func pagination() async throws {
        let dashboard = DemoFixtures.dashboards[0]
        let provider = PaginationTestProvider(dashboard: dashboard)
        let cache = MemorySnapshotCache()
        let reads = ReviewReadStore()
        let repository = DashboardRepository(
            provider: provider,
            cache: cache,
            historyStore: ReleaseHistoryStore(),
            readStore: reads
        )

        let first = try await repository.refresh()
        #expect(first.dashboards[0].reviews.count == dashboard.reviews.count)
        let updated = try await repository.loadMoreReviews(for: dashboard.id, in: first)
        #expect(updated.dashboards[0].reviews.count == dashboard.reviews.count + 1)
        #expect(Set(updated.dashboards[0].reviews.map(\.id)).count == updated.dashboards[0].reviews.count)
        #expect(await reads.unreadCount(in: updated.dashboards[0].reviews) == 0)
        #expect(await cache.load() == updated)
    }
}

private actor PaginationTestProvider: DashboardDataProviding {
    private let dashboard: AppDashboard

    init(dashboard: AppDashboard) {
        self.dashboard = dashboard
    }

    func fetchApps() -> [DeveloperApp] {
        [dashboard.app]
    }

    func fetchDashboard(for app: DeveloperApp) -> AppDashboard {
        dashboard
    }

    func fetchReviewsPage(at url: URL) -> ReviewPage {
        ReviewPage(
            reviews: [dashboard.reviews[0], DemoFixtures.olderReviews[0]],
            nextPage: nil
        )
    }
}
