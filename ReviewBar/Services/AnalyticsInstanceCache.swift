import CryptoKit
import Foundation

struct AnalyticsInstanceArchive: Codable, Sendable {
    let reportName: String
    let processingDay: AnalyticsDay
    let series: [AnalyticsMetricSeries]
}

protocol AnalyticsInstanceCaching: Sendable {
    func load(instanceID: String, reportName: String, processingDay: AnalyticsDay) async throws -> [AnalyticsMetricSeries]?
    func save(_ archive: AnalyticsInstanceArchive, instanceID: String) async throws
    func clear() async throws
    func sizeInBytes() async -> Int64
}

actor AnalyticsInstanceCache: AnalyticsInstanceCaching {
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directoryURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directoryURL = directoryURL
            ?? base.appending(path: "ReviewBar/Analytics-v1/Instances", directoryHint: .isDirectory)
    }

    func load(instanceID: String, reportName: String, processingDay: AnalyticsDay) throws -> [AnalyticsMetricSeries]? {
        let url = fileURL(instanceID: instanceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let archive: AnalyticsInstanceArchive
        do {
            archive = try decoder.decode(AnalyticsInstanceArchive.self, from: data)
        } catch is DecodingError {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        guard archive.reportName == reportName, archive.processingDay == processingDay else { return nil }
        return archive.series
    }

    func save(_ archive: AnalyticsInstanceArchive, instanceID: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directoryURL
        try? protectedDirectory.setResourceValues(values)
        try encoder.encode(archive).write(
            to: fileURL(instanceID: instanceID),
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
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func fileURL(instanceID: String) -> URL {
        let digest = SHA256.hash(data: Data(instanceID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appending(path: "\(digest).json")
    }
}

actor MemoryAnalyticsInstanceCache: AnalyticsInstanceCaching {
    private var archives: [String: AnalyticsInstanceArchive] = [:]

    func load(instanceID: String, reportName: String, processingDay: AnalyticsDay) -> [AnalyticsMetricSeries]? {
        guard let archive = archives[instanceID],
              archive.reportName == reportName,
              archive.processingDay == processingDay else { return nil }
        return archive.series
    }

    func save(_ archive: AnalyticsInstanceArchive, instanceID: String) {
        archives[instanceID] = archive
    }

    func clear() { archives = [:] }
    func sizeInBytes() -> Int64 { 0 }
}
