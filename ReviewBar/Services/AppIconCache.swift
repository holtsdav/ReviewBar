import CryptoKit
import Foundation
import ImageIO

protocol AppIconLoading: Sendable {
    func data(for url: URL) async throws -> Data
    func clear() async throws
    func sizeInBytes() async -> Int64
}

actor AppIconCache: AppIconLoading {
    static let shared = AppIconCache()

    private let directoryURL: URL
    private let session: URLSession
    private var inFlight: [URL: Task<Data, Error>] = [:]
    private var generation = 0
    private var isClearing = false
    private let maximumBytes = 12 * 1_024 * 1_024
    private let maximumTotalBytes = 64 * 1_024 * 1_024

    init(directoryURL: URL? = nil, session: URLSession? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directoryURL = directoryURL ?? caches.appending(path: "ReviewBar/AppIcons", directoryHint: .isDirectory)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(
                configuration: configuration,
                delegate: ImageRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func data(for url: URL) async throws -> Data {
        guard !isClearing else { throw CancellationError() }
        try Self.validate(url)
        let fileURL = cachedFileURL(for: url)
        if let cached = try? Data(contentsOf: fileURL), Self.isDecodableImage(cached) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: fileURL.path)
            return cached
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let task = inFlight[url] {
            return try await task.value
        }

        let session = self.session
        let maximumBytes = self.maximumBytes
        let expectedGeneration = generation
        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") == true,
                  !data.isEmpty,
                  data.count <= maximumBytes,
                  Self.isDecodableImage(data) else {
                throw AppError(kind: .malformedResponse, message: "Apple's app icon could not be loaded.")
            }
            return data
        }
        inFlight[url] = task
        do {
            let data = try await task.value
            guard generation == expectedGeneration else { throw CancellationError() }
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try evictIfNeeded(for: data.count)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            inFlight[url] = nil
            return data
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    func clear() async throws {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        generation += 1
        let tasks = Array(inFlight.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        inFlight = [:]
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    func sizeInBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private func cachedFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appending(path: "\(digest).image")
    }

    private func evictIfNeeded(for incomingByteCount: Int) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let entries = files.map { url -> (URL, Int, Date) in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total + incomingByteCount > maximumTotalBytes {
            try FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            throw AppError(kind: .malformedResponse, message: "Apple returned an unsafe app icon URL.")
        }
    }
}

private final class ImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              destination.scheme?.lowercased() == "https",
              destination.user == nil,
              destination.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
