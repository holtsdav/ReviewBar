import Foundation

struct ReviewFilter: Equatable, Sendable {
    var ratings: Set<Int> = []
    var territory: String?
    var appVersion: String?
    var sort: Sort = .newest

    enum Sort: String, CaseIterable, Sendable {
        case newest
        case oldest

        var title: String { rawValue.capitalized }
    }

    func apply(to reviews: [CustomerReview]) -> [CustomerReview] {
        reviews
            .filter { ratings.isEmpty || ratings.contains($0.rating) }
            .filter { territory == nil || $0.territory == territory }
            .filter { appVersion == nil || $0.appVersion == appVersion }
            .sorted {
                sort == .newest ? $0.createdDate > $1.createdDate : $0.createdDate < $1.createdDate
            }
    }
}

