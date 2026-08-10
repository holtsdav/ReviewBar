import SwiftUI

struct ReviewSummaryView: View {
    let reviews: [CustomerReview]
    let unreadIDs: Set<String>

    var body: some View {
        Section("Loaded Reviews") {
            LabeledContent("Average Rating") {
                HStack(spacing: 6) {
                    StarRatingView(rating: Int(averageRating.rounded()))
                    Text(averageRating, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                }
            }
            LabeledContent("Unread", value: reviews.count(where: { unreadIDs.contains($0.id) }).formatted())
            LabeledContent("Developer Responses", value: responseCoverage)
        }
    }

    private var averageRating: Double {
        guard reviews.isEmpty == false else { return 0 }
        return Double(reviews.reduce(0) { $0 + $1.rating }) / Double(reviews.count)
    }

    private var responseCoverage: String {
        guard reviews.isEmpty == false else { return "0 · 0%" }
        let responseCount = reviews.count(where: { $0.hasDeveloperResponse })
        let percentage = Double(responseCount) / Double(reviews.count)
        return "\(responseCount.formatted()) · \(percentage.formatted(.percent.precision(.fractionLength(0))))"
    }
}
