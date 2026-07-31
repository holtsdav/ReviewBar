import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDisconnect = false
    @State private var showingSecurity = false
    @State private var showingLimitations = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Data source") {
                        Label(model.source == .demo ? "Local Demo" : "App Store Connect",
                              systemImage: model.source == .demo ? "sparkles" : "checkmark.circle.fill")
                    }
                    if let updated = model.lastUpdated {
                        LabeledContent("Last updated", value: DisplayFormatters.dateTime(updated))
                    }
                    Button("Refresh Now", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isRefreshing)
                }

                Section("Data & Privacy") {
                    Button("How ReviewBar Protects Your Key", systemImage: "lock.shield") {
                        showingSecurity = true
                    }
                    Button("Apple API Limitations", systemImage: "info.circle") {
                        showingLimitations = true
                    }
                }

                Section {
                    Button(model.source == .demo ? "Exit Demo" : "Remove Connection", role: .destructive) {
                        confirmingDisconnect = true
                    }
                } footer: {
                    Text("This removes the imported credential, cached dashboards, unread state, and locally observed release history from ReviewBar.")
                }

                Section("About") {
                    LabeledContent("ReviewBar", value: "1.0")
                    Text("A focused, read-only App Store developer dashboard.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                model.source == .demo ? "Exit the local demo?" : "Remove this App Store Connect connection?",
                isPresented: $confirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button(model.source == .demo ? "Exit Demo" : "Remove Connection", role: .destructive) {
                    Task {
                        await model.disconnect()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingSecurity) {
                InformationSheet(
                    title: "Credential Security",
                    sections: [
                        ("On this device", "The imported private key and its identifiers are stored together in the iOS Keychain with a this-device-only protection class. They are never placed in UserDefaults, dashboard caches, or demo fixtures."),
                        ("Direct requests", "ReviewBar creates short-lived ES256 tokens in memory and sends read-only requests directly to Apple. It has no ReviewBar account or backend."),
                        ("Your original file", "ReviewBar cannot delete or protect the original .p8 file in Files. Keep that copy secure, and revoke the key in App Store Connect if you believe it has been exposed.")
                    ]
                )
            }
            .sheet(isPresented: $showingLimitations) {
                InformationSheet(
                    title: "Apple API Limitations",
                    sections: [
                        ("Release timing", "Apple provides the submission date but not a timestamp for every review-state transition. ReviewBar labels locally observed changes and treats their durations as approximate."),
                        ("Reviews", "App-level customer review objects do not include the reviewed app version or an Apple-side unread flag. Version appears only when it is legitimately known; unread state is device-local."),
                        ("Background updates", "Without a backend, iOS background refresh is opportunistic and cannot promise real-time alerts. ReviewBar remains fully useful through foreground refresh and caching.")
                    ]
                )
            }
        }
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

