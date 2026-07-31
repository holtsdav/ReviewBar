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
            if issue.usingCachedData == true, let cachedAt = issue.cachedAt {
                Label("Showing saved data from \(DisplayFormatters.dateTime(cachedAt))", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if issue.usingCachedData == true { return "Couldn’t Update This Section" }
        return switch issue.kind {
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
