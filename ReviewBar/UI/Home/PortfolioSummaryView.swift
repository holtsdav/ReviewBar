import SwiftUI

struct PortfolioSummaryView: View {
    let appCount: Int
    let favoriteCount: Int
    let attentionCount: Int
    let unreadReviewCount: Int
    let lastUpdated: Date?

    var body: some View {
        Section {
            LabeledContent("Apps", value: appCount.formatted())
            if favoriteCount > 0 {
                LabeledContent("Favorites", value: favoriteCount.formatted())
            }
            if attentionCount > 0 {
                LabeledContent {
                    Text(attentionCount.formatted())
                } label: {
                    Label("Need Attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if unreadReviewCount > 0 {
                LabeledContent("Unread Reviews", value: unreadReviewCount.formatted())
            }
        } header: {
            Text("Portfolio")
        } footer: {
            if let lastUpdated {
                Text("Updated \(DisplayFormatters.relative(lastUpdated)).")
            }
        }
    }
}
