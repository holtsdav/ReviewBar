import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDisconnect = false
    @State private var confirmingClearCache = false
    @State private var showingSecurity = false
    @State private var showingLimitations = false
    @State private var cacheSize: Int64?

    var body: some View {
        NavigationStack {
            List {
                accountSection
                dataSection
                notificationsSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await updateCacheSize() }
            .refreshable { await updateCacheSize() }
            .confirmationDialog(disconnectTitle, isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button(disconnectActionTitle, role: .destructive) {
                    Task { await disconnectConnection() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Clear ReviewBar's cached data?", isPresented: $confirmingClearCache) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await model.clearCachedData()
                        await updateCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("App Store Connect credentials stay in the Keychain. Dashboard snapshots, Analytics reports, and downloaded app icons will be removed.")
            }
            .sheet(isPresented: $showingSecurity) { securitySheet }
            .sheet(isPresented: $showingLimitations) { limitationsSheet }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            SettingsValueRow(
                title: "App Store Connect",
                value: "Connected",
                symbol: "person.crop.circle"
            )
            Button("Manage Connection", systemImage: "key") {
                confirmingDisconnect = true
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            SettingsValueRow(
                title: "Data Source",
                value: "Live",
                symbol: "externaldrive"
            )
            SettingsValueRow(
                title: "Last Refresh",
                value: model.lastUpdated.map { DisplayFormatters.relative($0) } ?? "Never",
                symbol: "clock"
            )
            SettingsValueRow(
                title: "Cache",
                value: cacheDescription,
                symbol: "internaldrive"
            )
            Button("Refresh Now", systemImage: "arrow.clockwise") {
                Task {
                    await model.refresh()
                    await updateCacheSize()
                }
            }
            .disabled(model.isRefreshing)
            Button("Clear Cache", systemImage: "trash", role: .destructive) {
                confirmingClearCache = true
            }
            .disabled((cacheSize ?? 0) == 0)
        }
    }

    private var notificationsSection: some View {
        Section {
            NavigationLink {
                RealTimeStatusSettingsView(model: model)
            } label: {
                SettingsValueRow(
                    title: "Real-Time Status Updates",
                    value: realtimeStatus,
                    symbol: "bell.badge"
                )
            }
            .accessibilityIdentifier("settings-realtime-updates")
        } header: {
            Text("Notifications")
        } footer: {
            Text("Optional status notifications use Apple's official App Store Connect webhooks. Customer-review webhooks are not available.")
        }
    }

    private var privacySection: some View {
        Section("Data & Privacy") {
            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            Button("How ReviewBar Protects Your Key", systemImage: "lock.shield") {
                showingSecurity = true
            }
            Button("Apple API Limitations", systemImage: "info.circle") {
                showingLimitations = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            SettingsValueRow(title: "Version", value: appVersion, symbol: "info.circle")
            Text("A focused App Store developer dashboard.")
                .foregroundStyle(.secondary)
        }
    }

    private var securitySheet: some View {
        InformationSheet(
            title: "Credential Security",
            sections: [
                ("On this device", "The imported private key and its identifiers use an iOS Keychain this-device-only protection class. They never enter UserDefaults, dashboard caches, or notification relay requests."),
                ("Direct Apple requests", "ReviewBar creates short-lived ES256 tokens in memory. The iPhone talks directly to App Store Connect, including user-initiated Analytics report and webhook configuration requests."),
                ("Notification relay", "If real-time updates are enabled, the relay receives Apple webhook events and sends ReviewBar push notifications. It never receives your App Store Connect private key, issuer ID, or JWT."),
                ("Your original file", "ReviewBar cannot delete or protect the original .p8 file in Files. Keep that copy secure, and revoke the key in App Store Connect if you believe it has been exposed.")
            ]
        )
    }

    private var limitationsSheet: some View {
        InformationSheet(
            title: "Apple API Limitations",
            sections: [
                ("Release timing", "ReviewBar prefers exact Apple webhook timestamps, then Apple API dates, then clearly labeled locally observed changes. Not every Apple event includes a transition timestamp."),
                ("Reviews", "Apple does not currently offer a customer App Store review-created webhook. Review notifications cannot be real-time; unread state remains device-local."),
                ("Analytics", "Analytics Reports are delayed, may take 24–48 hours to appear initially, and retain daily report instances for a limited period. ReviewBar always shows the actual data-through date."),
                ("Build history", "ReviewBar follows Apple’s complete paginated Build response for each app so active cross-platform and TestFlight builds are not hidden."),
                ("Notifications", "Real-time status updates require an optional public relay and an Account Holder, Admin, or App Manager role to create Apple webhooks.")
            ]
        )
    }

    private var disconnectTitle: String {
        "Remove this App Store Connect connection?"
    }

    private var disconnectActionTitle: String {
        "Remove Connection"
    }

    private var cacheDescription: String {
        guard let cacheSize else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    private var realtimeStatus: String {
        guard model.realtimeRelayIsConfigured else { return "Unavailable" }
        let count = model.realtimeInstallation?.channels.count ?? 0
        return count == 0 ? "Off" : "\(count) \(count == 1 ? "App" : "Apps")"
    }

    private func updateCacheSize() async {
        cacheSize = await model.cachedDataSizeInBytes()
    }

    private func disconnectConnection() async {
        if await model.disconnect() {
            dismiss()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

private struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section("Core App") {
                Text("ReviewBar has no account. Your App Store Connect private key and identifiers stay in this device's Keychain. The app sends authenticated dashboard and Analytics requests directly to Apple and stores decoded cache data on this device.")
            }
            Section("Optional Real-Time Updates") {
                Text("If you opt in, ReviewBar's Cloudflare relay processes an APNs device token, opaque installation identifier, selected app ID and name, notification preferences, Apple webhook ID, and normalized status-event metadata. This information is used only to deliver notifications, deduplicate events, and preserve authoritative transition times. It is not used for tracking, advertising, or analytics.")
            }
            Section("Protection and Sharing") {
                Text("Relay authentication tokens are hashed; APNs tokens and Apple webhook secrets are encrypted at rest. Cloudflare provides the hosting, database, and queue infrastructure, and Apple provides App Store Connect webhooks and APNs delivery. ReviewBar does not sell this data or share it for advertising.")
            }
            Section("Retention and Deletion") {
                Text("Normalized relay events are retained for no more than 30 days. Disabling an app removes its relay channel and events. Disabling the final app or removing the connection removes the installation registration. Local dashboard, Analytics, icon, review-read, and release-history data can be cleared in Settings and is erased when the connection is removed.")
            }
            Section("Your Choices") {
                Text("Real-time updates are optional. You can revoke notification permission in iOS Settings, disable individual apps in ReviewBar, remove the connection, or revoke the App Store Connect key in Apple's Users and Access settings.")
            }
            Section("Policy and Contact") {
                Text("Policy version 0.1.1 · Updated August 1, 2026")
                Text("Before public App Store submission, the distributor must publish this policy at its support website, add that URL to App Store Connect, and provide an operational privacy contact.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InformationSheet: View {
    let title: String
    let sections: [(String, String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section(section.0) { Text(section.1) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
