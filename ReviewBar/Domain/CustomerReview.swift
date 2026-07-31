import Foundation

struct CustomerReview: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let rating: Int
    let title: String
    let body: String
    let reviewerNickname: String
    let territory: String?
    let createdDate: Date
    let appVersion: String?
    let hasDeveloperResponse: Bool
}

