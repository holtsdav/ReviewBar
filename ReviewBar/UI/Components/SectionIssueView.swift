import SwiftUI

struct SectionIssueView: View {
    let issue: SectionIssue
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(issue.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch issue.kind {
        case .permission: "Permission Required"
        case .offline: "You’re Offline"
        case .rateLimited: "Refresh Paused"
        case .unavailable: "Apple Unavailable"
        case .malformedResponse: "Unexpected Apple Response"
        case .other: "Couldn’t Load This Section"
        }
    }

    private var symbol: String {
        switch issue.kind {
        case .permission: "lock.trianglebadge.exclamationmark"
        case .offline: "wifi.slash"
        case .rateLimited: "clock.badge.exclamationmark"
        case .unavailable: "cloud.slash"
        case .malformedResponse, .other: "exclamationmark.triangle"
        }
    }
}

