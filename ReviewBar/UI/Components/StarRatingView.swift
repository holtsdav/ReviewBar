import SwiftUI

struct StarRatingView: View {
    let rating: Double

    init(rating: Int) {
        self.rating = Double(min(max(rating, 0), 5))
    }

    init(rating: Double) {
        self.rating = min(max(rating, 0), 5)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: symbol(for: value))
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(formattedRating) out of 5 stars")
    }

    private var formattedRating: String {
        let fractionLength = rating.rounded() == rating ? 0 : 1
        return rating.formatted(.number.precision(.fractionLength(fractionLength)))
    }

    private func symbol(for value: Int) -> String {
        let threshold = Double(value)
        let visualRating = (rating * 2).rounded() / 2
        if visualRating >= threshold { return "star.fill" }
        if visualRating >= threshold - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}
