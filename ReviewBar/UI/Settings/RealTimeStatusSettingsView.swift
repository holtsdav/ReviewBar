import SwiftUI

struct RealTimeStatusSettingsView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Real-Time Updates", value: statusText)
                    .accessibilityIdentifier("realtime-status")
                if let statusMessage {
                    Label(statusMessage, systemImage: statusSymbol)
                        .foregroundStyle(statusColor)
                }
                Label("App Store Connect credentials remain on this iPhone.", systemImage: "iphone.and.arrow.forward")
                    .foregroundStyle(.secondary)
            }

            if model.realtimeRelayIsConfigured {
                Section("Apps") {
                    if model.dashboards.isEmpty {
                        Text("Your apps will appear here after the next refresh.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.dashboards) { dashboard in
                            NavigationLink {
                                RealtimeAppSettingsView(model: model, dashboard: dashboard)
                            } label: {
                                HStack(spacing: 12) {
                                    AppIconView(asset: dashboard.app.iconAsset, appName: dashboard.app.name, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dashboard.app.name)
                                        Text(dashboard.availablePlatforms.map(\.label).joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(model.realtimeIsEnabled(appID: dashboard.id) ? "On" : "Off")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("How It Works") {
                SetupStep(number: 1, text: "ReviewBar registers this device with its minimal notification relay.")
                SetupStep(number: 2, text: "This iPhone creates official App Store Connect webhooks using your on-device credential.")
                SetupStep(number: 3, text: "Apple sends status events to the relay, which forwards a push notification.")
            }

            Section("Apple Role Required") {
                Text("Account Holder, Admin, or App Manager")
                Text("Apple does not provide a customer-review-created webhook, so review alerts remain refresh-based.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Real-Time Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.prepareRealtimeState() }
    }

    private var statusText: String {
        switch model.realtimeSetupState {
        case .loading: "Checking…"
        case .ready:
            model.realtimeInstallation?.channels.isEmpty == false ? "On" : "Off"
        case .configuring: "Updating…"
        case .unavailable: "Unavailable"
        case .failed: "Needs Attention"
        }
    }

    private var statusMessage: String? {
        switch model.realtimeSetupState {
        case .unavailable(let message), .failed(let message): message
        case .loading: "Checking this device's saved notification configuration."
        case .configuring: "Keep ReviewBar open while Apple and the relay finish setup."
        case .ready: nil
        }
    }

    private var statusSymbol: String {
        switch model.realtimeSetupState {
        case .failed: "exclamationmark.triangle"
        case .unavailable: "bell.slash"
        default: "hourglass"
        }
    }

    private var statusColor: Color {
        if case .failed = model.realtimeSetupState { return .orange }
        return .secondary
    }
}

private struct RealtimeAppSettingsView: View {
    let model: AppModel
    let dashboard: AppDashboard
    @State private var selectedEvents: Set<AppStoreConnectWebhookEventType> = [
        .appVersionStateUpdated,
        .buildUploadStateUpdated,
        .externalBuildStateUpdated
    ]

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AppIconView(asset: dashboard.app.iconAsset, appName: dashboard.app.name, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dashboard.app.name)
                            .font(.headline)
                        Text(dashboard.availablePlatforms.map(\.label).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Monitoring", value: channel == nil ? "Off" : "On")
            }

            if let channel {
                Section("Events") {
                    ForEach(channel.eventTypes, id: \.self) { event in
                        Label(event.displayName, systemImage: event.symbolName)
                    }
                }
                Section {
                    Button("Disable Real-Time Updates", systemImage: "bell.slash", role: .destructive) {
                        Task { await model.disableRealtime(appID: dashboard.id) }
                    }
                    .disabled(isConfiguring)
                } footer: {
                    Text("ReviewBar removes both the App Store Connect webhook and this device's relay channel.")
                }
            } else {
                Section("Before You Enable") {
                    Text("ReviewBar sends this device's APNs token, an opaque installation ID, the selected app's ID and name, and your event preferences to a Cloudflare relay. The relay retains normalized status events for up to 30 days so it can deduplicate delivery and update release history. It never receives your App Store Connect key, issuer ID, or JWT.")
                    Text("Disabling removes the relay channel and its stored events. Disabling the last app also removes this device registration. If Apple can't delete its webhook, ReviewBar stops relay processing and tells you how to remove the stale webhook manually.")
                        .foregroundStyle(.secondary)
                }
                Section("Notify Me About") {
                    eventToggle(.appVersionStateUpdated)
                    eventToggle(.buildUploadStateUpdated)
                    eventToggle(.externalBuildStateUpdated)
                }
                Section {
                    Button("Enable Real-Time Updates", systemImage: "bell.badge") {
                        let events = AppStoreConnectWebhookEventType.allCases.filter(selectedEvents.contains)
                        Task { await model.enableRealtime(appID: dashboard.id, eventTypes: events) }
                    }
                    .disabled(selectedEvents.isEmpty || isConfiguring)
                } footer: {
                    Text("iOS asks for notification permission, then this device creates an official Apple webhook. Apple limits webhook creation to Account Holder, Admin, and App Manager roles.")
                }
            }

            if case .failed(let message) = model.realtimeSetupState {
                Section("Setup Issue") {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Customer Reviews") {
                Text("Apple does not currently provide a customer-review-created webhook. New reviews are detected when ReviewBar refreshes.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var channel: RealtimeChannel? {
        model.realtimeInstallation?.channels.first { $0.appID == dashboard.id }
    }

    private var isConfiguring: Bool {
        if case .configuring(let appID) = model.realtimeSetupState { return appID == dashboard.id }
        return false
    }

    private func eventToggle(_ event: AppStoreConnectWebhookEventType) -> some View {
        Toggle(isOn: Binding(
            get: { selectedEvents.contains(event) },
            set: { enabled in
                if enabled { selectedEvents.insert(event) }
                else { selectedEvents.remove(event) }
            }
        )) {
            Label(event.displayName, systemImage: event.symbolName)
        }
    }
}

private extension AppStoreConnectWebhookEventType {
    var displayName: String {
        switch self {
        case .appVersionStateUpdated: "Release status changes"
        case .buildUploadStateUpdated: "Build upload processing"
        case .externalBuildStateUpdated: "External TestFlight status"
        case .betaCrashFeedbackCreated: "TestFlight crash feedback"
        case .betaScreenshotFeedbackCreated: "TestFlight screenshot feedback"
        }
    }

    var symbolName: String {
        switch self {
        case .appVersionStateUpdated: "shippingbox"
        case .buildUploadStateUpdated: "hammer"
        case .externalBuildStateUpdated: "person.2.badge.gearshape"
        case .betaCrashFeedbackCreated: "exclamationmark.triangle"
        case .betaScreenshotFeedbackCreated: "photo.badge.exclamationmark"
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(.tint, in: .circle)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}
