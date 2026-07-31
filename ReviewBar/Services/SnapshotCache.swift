import Foundation

protocol SnapshotCaching: Sendable {
    func load() async throws -> DashboardCollection?
    func save(_ collection: DashboardCollection) async throws
    func clear() async throws
}

actor SnapshotCache: SnapshotCaching {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? baseURL.appending(path: "ReviewBar/snapshot-v1.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> DashboardCollection? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(DashboardCollection.self, from: Data(contentsOf: fileURL))
    }

    func save(_ collection: DashboardCollection) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(collection)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

actor MemorySnapshotCache: SnapshotCaching {
    private var collection: DashboardCollection?

    init(collection: DashboardCollection? = nil) {
        self.collection = collection
    }

    func load() -> DashboardCollection? { collection }
    func save(_ collection: DashboardCollection) { self.collection = collection }
    func clear() { collection = nil }
}

