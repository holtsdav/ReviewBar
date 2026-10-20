import Foundation
import Testing
@testable import ReviewBar

#if DEBUG
@MainActor
struct StartupTests {
    @Test("Dedicated scheme launches the inert host before any live factory",
          .enabled(if: ProcessInfo.processInfo.arguments.contains("-reviewbar-service-free-tests"),
                   "Requires the ReviewBar Service-Free Tests scheme"))
    func verifiedTestEntry() throws {
        let startup = ReviewBarStartup.current
        try #require(startup.isServiceFreeTestHost, "Use the ReviewBar Service-Free Tests scheme.")
        var liveCalls = 0
        var notificationCalls = 0
        let model = startup.makeModel {
            liveCalls += 1
            return .preview()
        }
        startup.configureNotifications { notificationCalls += 1 }
        #expect(model == nil)
        #expect(liveCalls == 0)
        #expect(notificationCalls == 0)
    }

    @Test("Only the exact explicit argument selects the service-free host", arguments: [
        [], ["-ui-testing-fixture"], ["-reviewbar-service-free-test"],
        ["-reviewbar-service-free-tests=false"]
    ])
    func ordinaryLaunchKeepsItsFactories(arguments: [String]) {
        let startup = ReviewBarStartup(arguments: arguments)
        var liveCalls = 0
        var notificationCalls = 0
        let fixture = AppModel.preview()
        let model = startup.makeModel {
            liveCalls += 1
            return fixture
        }
        startup.configureNotifications { notificationCalls += 1 }
        #expect(!startup.isServiceFreeTestHost)
        #expect(model === fixture)
        #expect(liveCalls == 1)
        #expect(notificationCalls == 1)
    }

    @Test("The host ignores unrelated fixture and reset flags")
    func hostTakesPriority() {
        let startup = ReviewBarStartup(arguments: [
            "-reviewbar-service-free-tests", "-ui-testing-reset", "-ui-testing-fixture"
        ])
        var calls = 0
        #expect(startup.makeModel { calls += 1; return .preview() } == nil)
        startup.configureNotifications { calls += 1 }
        #expect(calls == 0)
    }

    @Test("Synthetic dashboard refresh uses only memory fixtures")
    func syntheticRuntimeRefresh() async {
        let fixture = AppModel.preview()
        await fixture.refresh()
        #expect(fixture.session == .ready)
        #expect(fixture.dashboards.map(\.app) == DemoFixtures.dashboards.map(\.app))
        #expect(fixture.dashboards.flatMap(\.reviews) == DemoFixtures.dashboards.flatMap(\.reviews))
        #expect(fixture.presentedError == nil)
        #expect(!fixture.realtimeRelayIsConfigured)
        fixture.preferences.toggleFavorite(appID: "synthetic-only")
        #expect(fixture.preferences.favoriteAppIDs.contains("synthetic-only"))
        #expect(!AppModel.preview().preferences.favoriteAppIDs.contains("synthetic-only"))
    }
}
#endif
