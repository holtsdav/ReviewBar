import Foundation

struct ReviewFilter: Equatable, Sendable {
    var ratings: Set<Int> = []
    var territory: String?
    var appVersion: String?
    var sort: Sort = .newest
    var query = ""
    var unreadOnly = false
    var response: Response = .all

    enum Sort: String, CaseIterable, Sendable {
        case newest
        case oldest

        var title: String { rawValue.capitalized }
    }

    enum Response: String, CaseIterable, Sendable {
        case all
        case withResponse
        case withoutResponse

        var title: String {
            switch self {
            case .all: "Any Response State"
            case .withResponse: "Has Developer Response"
            case .withoutResponse: "Needs Developer Response"
            }
        }
    }

    var activeCriteriaCount: Int {
        (ratings.isEmpty ? 0 : 1)
            + (territory == nil ? 0 : 1)
            + (appVersion == nil ? 0 : 1)
            + (query.isEmpty ? 0 : 1)
            + (unreadOnly ? 1 : 0)
            + (response == .all ? 0 : 1)
    }

    func apply(to reviews: [CustomerReview], unreadIDs: Set<String> = []) -> [CustomerReview] {
        apply(to: reviews, unreadIDs: unreadIDs, cancellationCheck: {})
    }

    func apply(
        to reviews: [CustomerReview],
        unreadIDs: Set<String> = [],
        cancellationCheck: () throws -> Void
    ) rethrows -> [CustomerReview] {
        var matches: [CustomerReview] = []
        matches.reserveCapacity(reviews.count)

        for (index, review) in reviews.enumerated() {
            if index.isMultiple(of: 128) { try cancellationCheck() }
            guard ratings.isEmpty || ratings.contains(review.rating) else { continue }
            guard territory == nil || review.territory == territory else { continue }
            guard appVersion == nil || review.appVersion == appVersion else { continue }
            guard !unreadOnly || unreadIDs.contains(review.id) else { continue }
            switch response {
            case .all: break
            case .withResponse where review.hasDeveloperResponse: break
            case .withoutResponse where review.hasDeveloperResponse == false: break
            default: continue
            }
            guard query.isEmpty
                    || review.title.localizedStandardContains(query)
                    || review.body.localizedStandardContains(query)
                    || review.reviewerNickname.localizedStandardContains(query)
                    || (review.territory?.localizedStandardContains(query) == true) else { continue }
            matches.append(review)
        }

        try cancellationCheck()
        return matches.sorted {
            sort == .newest ? $0.createdDate > $1.createdDate : $0.createdDate < $1.createdDate
        }
    }
}
