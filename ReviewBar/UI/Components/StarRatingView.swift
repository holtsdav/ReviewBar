import SwiftUI

struct StarRatingView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating) out of 5 stars")
    }
}

