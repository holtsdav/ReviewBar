import Foundation

protocol AnalyticsDataProviding: Sendable {
    func fetchAnalytics(appID: String) async throws -> AnalyticsFetchResult
    func createOngoingRequest(appID: String) async throws
    func clearImportedData() async throws
    func importedDataSizeInBytes() async -> Int64
}

extension AnalyticsDataProviding {
    func clearImportedData() async throws {}
    func importedDataSizeInBytes() async -> Int64 { 0 }
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
    private var inFlightGenerations: [String: Int] = [:]
    private var generation = 0
    private var isResetting = false

    init(provider: any AnalyticsDataProviding, cache: any AnalyticsCaching) {
        self.provider = provider
        self.cache = cache
    }

    func cached(appID: String) async throws -> AnalyticsDataset? {
        guard !isResetting else { return nil }
        return try await cache.load(appID: appID)
    }

    func refresh(appID: String) async throws -> AnalyticsFetchResult {
        guard !isResetting else { throw CancellationError() }
        if let task = inFlight[appID] { return try await task.value }
        let expectedGeneration = generation
        let provider = self.provider
        let cache = self.cache
        let task = Task<AnalyticsFetchResult, Error> {
            let result = try await provider.fetchAnalytics(appID: appID)
            try Task.checkCancellation()
            guard case .dataset(var incoming) = result else { return result }
            if var existing = try await cache.load(appID: appID) {
                existing.merge(incoming)
                incoming = existing
            }
            try Task.checkCancellation()
            try await cache.save(incoming)
            return .dataset(incoming)
        }
        inFlight[appID] = task
        inFlightGenerations[appID] = expectedGeneration
        do {
            let result = try await task.value
            guard generation == expectedGeneration else { throw CancellationError() }
            if inFlightGenerations[appID] == expectedGeneration {
                inFlight[appID] = nil
                inFlightGenerations[appID] = nil
            }
            return result
        } catch {
            if inFlightGenerations[appID] == expectedGeneration {
                inFlight[appID] = nil
                inFlightGenerations[appID] = nil
            }
            throw error
        }
    }

    func createOngoingRequest(appID: String) async throws {
        try await provider.createOngoingRequest(appID: appID)
    }

    func clear() async throws {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        await cancelTasks()
        try await provider.clearImportedData()
        try await cache.clear()
    }

    func cancelInFlight() async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        await cancelTasks()
    }

    private func cancelTasks() async {
        generation += 1
        let tasks = Array(inFlight.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        inFlight = [:]
        inFlightGenerations = [:]
    }

    func sizeInBytes() async -> Int64 {
        let cacheBytes = await cache.sizeInBytes()
        let importedBytes = await provider.importedDataSizeInBytes()
        return cacheBytes + importedBytes
    }
}
