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
                developerSection
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
                    Task { await disconnectOrExitDemo() }
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
                value: model.source == .demo ? "Demo Account" : "Connected",
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
                value: model.source == .demo ? "Local Demo" : "Live",
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
                    value: "Off",
                    symbol: "bell.badge"
                )
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Optional status notifications use Apple's official App Store Connect webhooks. Customer-review webhooks are not available.")
        }
    }

    private var developerSection: some View {
        Section("Developer") {
            SettingsValueRow(
                title: "Demo Mode",
                value: model.source == .demo ? "On" : "Off",
                symbol: "hammer"
            )
            Button(model.source == .demo ? "Exit Demo Mode" : "Enter Demo Mode", systemImage: "sparkles") {
                Task {
                    if model.source == .demo {
                        await model.exitDemo()
                    } else {
                        await model.enterDemo()
                    }
                }
            }
        }
    }

    private var privacySection: some View {
        Section("Data & Privacy") {
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
                ("On this device", "The imported private key and its identifiers use an iOS Keychain this-device-only protection class. They never enter UserDefaults, dashboard caches, demo fixtures, or notification relay requests."),
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
                ("Build history", "To keep refreshes efficient, ReviewBar loads Apple’s newest 200 builds for each app across supported platforms."),
                ("Notifications", "Real-time status updates require an optional public relay and an Account Holder, Admin, or App Manager role to create Apple webhooks.")
            ]
        )
    }

    private var disconnectTitle: String {
        model.source == .demo ? "Exit the local demo?" : "Remove this App Store Connect connection?"
    }

    private var disconnectActionTitle: String {
        model.source == .demo ? "Exit Demo" : "Remove Connection"
    }

    private var cacheDescription: String {
        guard let cacheSize else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    private func updateCacheSize() async {
        cacheSize = await model.cachedDataSizeInBytes()
    }

    private func disconnectOrExitDemo() async {
        if model.source == .demo {
            await model.exitDemo()
            if model.session == .signedOut { dismiss() }
        } else if await model.disconnect() {
            dismiss()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
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
