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
        reviews
            .filter { ratings.isEmpty || ratings.contains($0.rating) }
            .filter { territory == nil || $0.territory == territory }
            .filter { appVersion == nil || $0.appVersion == appVersion }
            .filter { !unreadOnly || unreadIDs.contains($0.id) }
            .filter {
                switch response {
                case .all: true
                case .withResponse: $0.hasDeveloperResponse
                case .withoutResponse: !$0.hasDeveloperResponse
                }
            }
            .filter {
                query.isEmpty
                    || $0.title.localizedStandardContains(query)
                    || $0.body.localizedStandardContains(query)
                    || $0.reviewerNickname.localizedStandardContains(query)
                    || ($0.territory?.localizedStandardContains(query) == true)
            }
            .sorted {
                sort == .newest ? $0.createdDate > $1.createdDate : $0.createdDate < $1.createdDate
            }
    }
}
