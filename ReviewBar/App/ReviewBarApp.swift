import SwiftUI

@main
struct ReviewBarApp: App {
    @UIApplicationDelegateAdaptor(ReviewBarAppDelegate.self) private var appDelegate
    @State private var model: AppModel?

    init() {
        _model = State(initialValue: ReviewBarStartup.current.makeModel())
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
                    .preferredColorScheme(uiTestingColorScheme)
            } else {
                Text("ReviewBar service-free test host")
                    .accessibilityIdentifier("service-free-test-host")
            }
        }
    }

    private var uiTestingColorScheme: ColorScheme? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing-dark") ? .dark : nil
        #else
        nil
        #endif
    }
}

/// Decide before constructing live stores or installing notification delegates.
/// This host intentionally renders no product views: those can load icons,
/// preferences and account state independently of AppModel.start().
@MainActor
struct ReviewBarStartup {
    static var current: Self { Self(arguments: ProcessInfo.processInfo.arguments) }

    let isServiceFreeTestHost: Bool

    init(arguments: [String]) {
        #if DEBUG
        isServiceFreeTestHost = arguments.contains("-reviewbar-service-free-tests")
        #else
        isServiceFreeTestHost = false
        #endif
    }

    func makeModel(liveModel: () -> AppModel = { AppModel.live() }) -> AppModel? {
        guard !isServiceFreeTestHost else { return nil }
        return liveModel()
    }

    func configureNotifications(_ configure: () -> Void) {
        guard !isServiceFreeTestHost else { return }
        configure()
    }
}
