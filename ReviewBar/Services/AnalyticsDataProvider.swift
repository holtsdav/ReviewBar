import Foundation

protocol AnalyticsDataProviding: Sendable {
    func fetchAnalytics(appID: String) async throws -> AnalyticsFetchResult
    func createOngoingRequest(appID: String) async throws
}

protocol AnalyticsCaching: Sendable {
    func load(appID: String) async throws -> AnalyticsDataset?
    func save(_ dataset: AnalyticsDataset) async throws
    func clear() async throws
    func sizeInBytes() async -> Int64
}

actor AnalyticsRepository {
    private let provider: any AnalyticsDataProviding
    private let cache: any AnalyticsCaching
    private var inFlight: [String: Task<AnalyticsFetchResult, Error>] = [:]

    init(provider: any AnalyticsDataProviding, cache: any AnalyticsCaching) {
        self.provider = provider
        self.cache = cache
    }

    func cached(appID: String) async throws -> AnalyticsDataset? {
        try await cache.load(appID: appID)
    }

    func refresh(appID: String) async throws -> AnalyticsFetchResult {
        if let task = inFlight[appID] { return try await task.value }
        let provider = self.provider
        let task = Task { try await provider.fetchAnalytics(appID: appID) }
        inFlight[appID] = task
        do {
            let result = try await task.value
            let merged: AnalyticsFetchResult
            if case .dataset(var incoming) = result {
                if var existing = try await cache.load(appID: appID) {
                    existing.merge(incoming)
                    incoming = existing
                }
                try await cache.save(incoming)
                merged = .dataset(incoming)
            } else {
                merged = result
            }
            inFlight[appID] = nil
            return merged
        } catch {
            inFlight[appID] = nil
            throw error
        }
    }

    func createOngoingRequest(appID: String) async throws {
        try await provider.createOngoingRequest(appID: appID)
    }

    func clear() async throws {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        try await cache.clear()
    }

    func sizeInBytes() async -> Int64 { await cache.sizeInBytes() }
}
