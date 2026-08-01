import CryptoKit
import Foundation

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
    private let maximumBytes = 12 * 1_024 * 1_024

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
        try Self.validate(url)
        let fileURL = cachedFileURL(for: url)
        if let cached = try? Data(contentsOf: fileURL), !cached.isEmpty {
            return cached
        }
        if let task = inFlight[url] {
            return try await task.value
        }

        let session = self.session
        let maximumBytes = self.maximumBytes
        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") == true,
                  !data.isEmpty,
                  data.count <= maximumBytes else {
                throw AppError(kind: .malformedResponse, message: "Apple's app icon could not be loaded.")
            }
            return data
        }
        inFlight[url] = task
        do {
            let data = try await task.value
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            inFlight[url] = nil
            return data
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    func clear() throws {
        for task in inFlight.values { task.cancel() }
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
