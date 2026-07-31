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
