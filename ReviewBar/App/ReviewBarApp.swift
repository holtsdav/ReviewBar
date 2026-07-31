import SwiftUI

@main
struct ReviewBarApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(uiTestingColorScheme)
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
