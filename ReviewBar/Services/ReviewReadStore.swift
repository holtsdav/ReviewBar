import Foundation

actor ReviewReadStore {
    private struct State: Codable {
        var initializedApps: Set<String> = []
        var readReviewIDs: Set<String> = []
    }

    private let fileURL: URL?
    private var state: State

    init(fileURL: URL? = nil, initiallyReadIDs: Set<String> = []) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State(readReviewIDs: initiallyReadIDs)
        }
    }

    static func live() -> ReviewReadStore {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ReviewReadStore(fileURL: baseURL.appending(path: "ReviewBar/review-state-v1.json"))
    }

    func reconcile(appID: String, reviews: [CustomerReview]) throws {
        if !state.initializedApps.contains(appID) {
            state.initializedApps.insert(appID)
            state.readReviewIDs.formUnion(reviews.map(\.id))
            try persist()
        }
    }

    func unreadCount(in reviews: [CustomerReview]) -> Int {
        reviews.lazy.filter { !self.state.readReviewIDs.contains($0.id) }.count
    }

    func unreadIDs(in reviews: [CustomerReview]) -> Set<String> {
        Set(reviews.lazy.filter { !self.state.readReviewIDs.contains($0.id) }.map(\.id))
    }

    func isUnread(_ review: CustomerReview) -> Bool {
        !state.readReviewIDs.contains(review.id)
    }

    func markRead(_ reviewID: String) throws {
        state.readReviewIDs.insert(reviewID)
        try persist()
    }

    func markAllRead(_ reviews: [CustomerReview]) throws {
        state.readReviewIDs.formUnion(reviews.map(\.id))
        try persist()
    }

    func clear() throws {
        state = State()
        try persist()
    }

    func configureDemo(appIDs: Set<String>, readReviewIDs: Set<String>) throws {
        state = State(initializedApps: appIDs, readReviewIDs: readReviewIDs)
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
