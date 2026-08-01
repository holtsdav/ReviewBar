import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.session {
            case .starting:
                LaunchView()
            case .signedOut:
                OnboardingView(model: model)
            case .ready:
                HomeView(model: model)
            }
        }
        .task {
            await model.start()
        }
        // Loading the optional notification-relay state can touch Keychain,
        // request an APNs token, and reconcile remote cleanup. Keep it out of
        // the launch critical path and start it only once the dashboard is
        // actually on screen. SwiftUI cancels this task when the session leaves
        // the ready state (for example, during disconnect).
        .task(id: model.session) {
            guard model.session == .ready else { return }
            #if DEBUG
            // Local fixtures own their in-memory notification state. Do not
            // hydrate the live Keychain store or overwrite that fixture state.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-fixture")
                || ProcessInfo.processInfo.arguments.contains("-ui-testing-empty")
                || ProcessInfo.processInfo.arguments.contains("-ui-testing-error") {
                return
            }
            #endif
            await Task.yield()
            await model.prepareRealtimeState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await model.refreshIfStale() }
        }
        .alert(model.presentedError?.title ?? "Connection Issue", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError?.message ?? "")
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            ProgressView("Opening ReviewBar…")
        }
    }
}

#Preview("Starting") {
    RootView(model: .preview(session: .starting))
}
