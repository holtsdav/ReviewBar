import SwiftUI

@main
struct ReviewBarApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

