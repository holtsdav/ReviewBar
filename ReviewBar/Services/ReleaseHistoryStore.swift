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
        var changed = false
        for release in releases {
            let previous = observations.last { $0.releaseID == release.id }
            guard previous?.state != release.state else { continue }
            observations.append(ReleaseObservation(
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
        if changed { try persist() }
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
            if let submitted = ordered.first(where: { $0.state == .waitingForReview }),
               let inReview = ordered.first(where: { $0.state == .inReview && $0.observedAt >= submitted.observedAt }) {
                waiting.append(inReview.observedAt.timeIntervalSince(submitted.observedAt))
                if let approved = ordered.first(where: {
                    [ReleaseState.pendingDeveloperRelease, .processingForDistribution, .readyForDistribution].contains($0.state)
                        && $0.observedAt >= inReview.observedAt
                }) {
                    reviewing.append(approved.observedAt.timeIntervalSince(inReview.observedAt))
                    approvals.append(approved.observedAt.timeIntervalSince(submitted.observedAt))
                }
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
        observations = []
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(observations).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}

private extension Collection where Element == TimeInterval {
    var average: TimeInterval? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
