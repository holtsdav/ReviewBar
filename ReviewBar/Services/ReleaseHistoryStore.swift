import Foundation

actor ReleaseHistoryStore {
    private let fileURL: URL?
    private var observations: [ReleaseObservation]

    init(fileURL: URL? = nil, observations: [ReleaseObservation] = []) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.observations = (try? decoder.decode([ReleaseObservation].self, from: data)) ?? observations
        } else {
            self.observations = observations
        }
    }

    static func live() -> ReleaseHistoryStore {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ReleaseHistoryStore(fileURL: baseURL.appending(path: "ReviewBar/release-history-v1.json"))
    }

    func record(_ releases: [AppRelease], appID: String, at date: Date = .now) throws {
        var candidate = observations
        var changed = false
        for release in releases {
            let previous = candidate.last { $0.releaseID == release.id }
            guard previous?.state != release.state else { continue }
            candidate.append(ReleaseObservation(
                id: UUID(),
                appID: appID,
                releaseID: release.id,
                version: release.version,
                state: release.state,
                observedAt: date,
                source: .localObservation
            ))
            changed = true
        }
        if changed {
            try persist(candidate)
            observations = candidate
        }
    }

    func observations(for releaseID: String) -> [ReleaseObservation] {
        observations.filter { $0.releaseID == releaseID }.sorted { $0.observedAt < $1.observedAt }
    }

    func statistics(appID: String) -> ReleaseStatistics {
        let appObservations = observations.filter { $0.appID == appID }
        let grouped = Dictionary(grouping: appObservations, by: \.releaseID)
        var waiting: [TimeInterval] = []
        var reviewing: [TimeInterval] = []
        var approvals: [TimeInterval] = []

        for values in grouped.values {
            let ordered = values.sorted { $0.observedAt < $1.observedAt }
            for approvalIndex in ordered.indices where approvedStates.contains(ordered[approvalIndex].state) {
                guard approvalIndex >= 2,
                      ordered[approvalIndex - 1].state == .inReview,
                      ordered[approvalIndex - 2].state == .waitingForReview else { continue }
                let submitted = ordered[approvalIndex - 2]
                let inReview = ordered[approvalIndex - 1]
                let approved = ordered[approvalIndex]
                waiting.append(inReview.observedAt.timeIntervalSince(submitted.observedAt))
                reviewing.append(approved.observedAt.timeIntervalSince(inReview.observedAt))
                approvals.append(approved.observedAt.timeIntervalSince(submitted.observedAt))
            }
        }

        return ReleaseStatistics(
            averageWaiting: waiting.average,
            averageInReview: reviewing.average,
            fastestApproval: approvals.min(),
            longestApproval: approvals.max(),
            completedReleaseCount: approvals.count
        )
    }

    func clear() throws {
        try persist([])
        observations = []
    }

    private func persist(_ candidate: [ReleaseObservation]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(candidate).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private var approvedStates: Set<ReleaseState> {
        [.pendingDeveloperRelease, .processingForDistribution, .readyForDistribution]
    }
}

private extension Collection where Element == TimeInterval {
    var average: TimeInterval? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
