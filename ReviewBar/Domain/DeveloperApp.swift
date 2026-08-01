import Foundation

struct DeveloperApp: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleID: String
    let sku: String?
    let primaryLocale: String?
    var iconAsset: AppIconAsset? = nil
}
