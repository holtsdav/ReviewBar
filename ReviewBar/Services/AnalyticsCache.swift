import Foundation

actor AnalyticsCache: AnalyticsCaching {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directoryURL = directoryURL ?? base.appending(path: "ReviewBar/Analytics-v1", directoryHint: .isDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load(appID: String) throws -> AnalyticsDataset? {
        let url = fileURL(appID: appID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(AnalyticsDataset.self, from: Data(contentsOf: url))
    }

    func save(_ dataset: AnalyticsDataset) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(dataset).write(
            to: fileURL(appID: dataset.appID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    func sizeInBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .reduce(0) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
    }

    private func fileURL(appID: String) -> URL {
        let safeID = appID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return directoryURL.appending(path: "\(safeID).json")
    }
}

actor MemoryAnalyticsCache: AnalyticsCaching {
    private var datasets: [String: AnalyticsDataset] = [:]

    init(datasets: [AnalyticsDataset] = []) {
        self.datasets = Dictionary(uniqueKeysWithValues: datasets.map { ($0.appID, $0) })
    }

    func load(appID: String) -> AnalyticsDataset? { datasets[appID] }
    func save(_ dataset: AnalyticsDataset) { datasets[dataset.appID] = dataset }
    func clear() { datasets = [:] }
    func sizeInBytes() -> Int64 { 0 }
}
