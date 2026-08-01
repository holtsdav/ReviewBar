import Foundation

actor ReviewReadStore {
    private struct State: Codable {
        var initializedApps: Set<String> = []
        var readReviewIDs: Set<String> = []
    }

    private let fileURL: URL?
    private var state: State
    private var hasLoadedPersistedState: Bool

    init(fileURL: URL? = nil, initiallyReadIDs: Set<String> = []) {
        self.fileURL = fileURL
        state = State(readReviewIDs: initiallyReadIDs)
        // Avoid synchronous disk I/O while the SwiftUI scene is being created.
        // The first actor operation hydrates the file off the main actor.
        hasLoadedPersistedState = fileURL == nil
    }

    static func live() -> ReviewReadStore {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ReviewReadStore(fileURL: baseURL.appending(path: "ReviewBar/review-state-v1.json"))
    }

    func reconcile(appID: String, reviews: [CustomerReview]) throws {
        loadPersistedStateIfNeeded()
        if !state.initializedApps.contains(appID) {
            var candidate = state
            candidate.initializedApps.insert(appID)
            candidate.readReviewIDs.formUnion(reviews.map(\.id))
            try persist(candidate)
            state = candidate
        }
    }

    func unreadCount(in reviews: [CustomerReview]) -> Int {
        loadPersistedStateIfNeeded()
        return reviews.lazy.filter { !self.state.readReviewIDs.contains($0.id) }.count
    }

    func unreadIDs(in reviews: [CustomerReview]) -> Set<String> {
        loadPersistedStateIfNeeded()
        return Set(reviews.lazy.filter { !self.state.readReviewIDs.contains($0.id) }.map(\.id))
    }

    func isUnread(_ review: CustomerReview) -> Bool {
        loadPersistedStateIfNeeded()
        return !state.readReviewIDs.contains(review.id)
    }

    func markRead(_ reviewID: String) throws {
        loadPersistedStateIfNeeded()
        var candidate = state
        candidate.readReviewIDs.insert(reviewID)
        try persist(candidate)
        state = candidate
    }

    func markAllRead(_ reviews: [CustomerReview]) throws {
        loadPersistedStateIfNeeded()
        var candidate = state
        candidate.readReviewIDs.formUnion(reviews.map(\.id))
        try persist(candidate)
        state = candidate
    }

    func clear() throws {
        loadPersistedStateIfNeeded()
        let candidate = State()
        try persist(candidate)
        state = candidate
    }

    #if DEBUG
    func configureFixture(appIDs: Set<String>, readReviewIDs: Set<String>) throws {
        loadPersistedStateIfNeeded()
        let candidate = State(initializedApps: appIDs, readReviewIDs: readReviewIDs)
        try persist(candidate)
        state = candidate
    }
    #endif

    private func loadPersistedStateIfNeeded() {
        guard !hasLoadedPersistedState else { return }
        hasLoadedPersistedState = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else { return }
        state = decoded
    }

    private func persist(_ candidate: State) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
