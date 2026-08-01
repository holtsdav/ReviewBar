import Foundation

/// A displayable image asset returned by App Store Connect. Apple supplies a
/// template URL rather than a fixed-size image URL.
struct AppIconAsset: Codable, Hashable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        case appStore
        case build
    }

    let templateURL: URL
    let width: Int?
    let height: Int?
    let source: Source

    func resolvedURL(pointSize: Int, scale: Int = 3, format: String = "png") -> URL? {
        guard pointSize > 0, scale > 0 else { return nil }
        let requestedPixels = pointSize * scale
        let boundedWidth = min(width ?? requestedPixels, requestedPixels)
        let boundedHeight = min(height ?? requestedPixels, requestedPixels)
        let resolved = templateURL.absoluteString
            .replacingOccurrences(of: "{w}", with: String(boundedWidth))
            .replacingOccurrences(of: "{h}", with: String(boundedHeight))
            .replacingOccurrences(of: "{f}", with: format)
            .replacingOccurrences(of: "%7Bw%7D", with: String(boundedWidth), options: .caseInsensitive)
            .replacingOccurrences(of: "%7Bh%7D", with: String(boundedHeight), options: .caseInsensitive)
            .replacingOccurrences(of: "%7Bf%7D", with: format, options: .caseInsensitive)
        guard !resolved.localizedCaseInsensitiveContains("%7Bw%7D"),
              !resolved.localizedCaseInsensitiveContains("%7Bh%7D"),
              !resolved.localizedCaseInsensitiveContains("%7Bf%7D"),
              !resolved.contains("{w}"), !resolved.contains("{h}"), !resolved.contains("{f}"),
              let url = URL(string: resolved),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }
}
