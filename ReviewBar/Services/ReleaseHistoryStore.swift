import Foundation

actor ReleaseHistoryStore {
    private let fileURL: URL?
    private var observations: [ReleaseObservation]
    private var hasLoadedPersistedState: Bool

    init(fileURL: URL? = nil, observations: [ReleaseObservation] = []) {
        self.fileURL = fileURL
        self.observations = observations
        // Loading is deliberately lazy. This actor is created while SwiftUI
        // builds the app scene, so reading a potentially large history file in
        // init would block the main thread during launch. The first actor
        // operation loads it on the actor's executor instead.
        self.hasLoadedPersistedState = fileURL == nil
    }

    static func live() -> ReleaseHistoryStore {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ReleaseHistoryStore(fileURL: baseURL.appending(path: "ReviewBar/release-history-v1.json"))
    }

    func record(_ releases: [AppRelease], appID: String, at date: Date = .now) throws {
        loadPersistedStateIfNeeded()
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

    /// Records an exact timestamp supplied by Apple, for example from an App
    /// Store Connect webhook. Event IDs make relay redelivery idempotent.
    func recordAuthoritative(
        eventID: String,
        appID: String,
        releaseID: String,
        version: String,
        state: ReleaseState,
        occurredAt: Date,
        source: ReleaseObservation.Source
    ) throws {
        loadPersistedStateIfNeeded()
        guard source != .localObservation,
              !observations.contains(where: { $0.externalEventID == eventID }) else { return }
        var candidate = observations
        candidate.append(ReleaseObservation(
            id: UUID(),
            appID: appID,
            releaseID: releaseID,
            version: version,
            state: state,
            observedAt: occurredAt,
            source: source,
            externalEventID: eventID
        ))
        try persist(candidate)
        observations = candidate
    }

    func observations(for releaseID: String) -> [ReleaseObservation] {
        loadPersistedStateIfNeeded()
        return preferredTimeline(observations.filter { $0.releaseID == releaseID })
    }

    func statistics(appID: String) -> ReleaseStatistics {
        loadPersistedStateIfNeeded()
        let appObservations = observations.filter { $0.appID == appID }
        let grouped = Dictionary(grouping: appObservations, by: \.releaseID)
        var waiting: [TimeInterval] = []
        var reviewing: [TimeInterval] = []
        var approvals: [TimeInterval] = []

        for values in grouped.values {
            let ordered = preferredTimeline(values)
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
        loadPersistedStateIfNeeded()
        try persist([])
        observations = []
    }

    private func loadPersistedStateIfNeeded() {
        guard !hasLoadedPersistedState else { return }
        hasLoadedPersistedState = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ReleaseObservation].self, from: data) {
            observations = decoded
        }
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

    /// Webhook delivery can arrive after a foreground refresh has already made
    /// a local observation. Collapse only consecutive copies of the same state,
    /// preferring the most authoritative source without erasing later review
    /// attempts that are separated by a different state.
    private func preferredTimeline(_ values: [ReleaseObservation]) -> [ReleaseObservation] {
        let ordered = values.sorted {
            if $0.observedAt == $1.observedAt { return $0.source.authority > $1.source.authority }
            return $0.observedAt < $1.observedAt
        }
        var result: [ReleaseObservation] = []
        for value in ordered {
            guard let last = result.last, last.state == value.state else {
                result.append(value)
                continue
            }
            if value.source.authority > last.source.authority {
                result[result.count - 1] = value
            }
        }
        return result
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
