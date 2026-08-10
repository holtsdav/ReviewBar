import Foundation

enum AppActivityFilter: String, CaseIterable, Sendable {
    case all
    case favorites
    case needsAttention
    case inReview
    case processing
    case newReviews

    var title: String {
        switch self {
        case .all: "All Apps"
        case .favorites: "Favorites"
        case .needsAttention: "Needs Attention"
        case .inReview: "In Review"
        case .processing: "Processing Builds"
        case .newReviews: "New Reviews"
        }
    }
}
