import SwiftUI

struct RealTimeStatusSettingsView: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: "Not Configured")
                Label("App Store Connect credentials remain on this iPhone.", systemImage: "iphone.and.arrow.forward")
                    .foregroundStyle(.secondary)
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

            Section {
                Button("Enable Real-Time Updates") {}
                    .disabled(true)
            } footer: {
                Text("A deployed ReviewBar notification relay URL and APNs configuration are required before setup can be enabled. See the repository's NotificationRelay documentation.")
            }
        }
        .navigationTitle("Real-Time Updates")
        .navigationBarTitleDisplayMode(.inline)
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
