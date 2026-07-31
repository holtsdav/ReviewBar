import Foundation

struct BuildInfo: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let buildNumber: String
    let version: String?
    let platform: AppRelease.Platform
    let uploadedDate: Date?
    let expirationDate: Date?
    let expired: Bool
    let processingState: ProcessingState
    let minimumOSVersion: String?
    var audienceType: String? = nil
    var internalBetaState: String? = nil
    var externalBetaState: String? = nil
    var betaReviewState: String? = nil
    var selectedForAppStoreVersion: String? = nil

    struct ProcessingState: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String

        static let processing = Self(rawValue: "PROCESSING")
        static let failed = Self(rawValue: "FAILED")
        static let invalid = Self(rawValue: "INVALID")
        static let valid = Self(rawValue: "VALID")

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(apiValue: String) {
            self.rawValue = apiValue
        }

        var title: String {
            switch rawValue {
            case Self.processing.rawValue: "Processing"
            case Self.failed.rawValue: "Failed"
            case Self.invalid.rawValue: "Invalid"
            case Self.valid.rawValue: "Ready"
            default: "Unknown (\(rawValue))"
            }
        }
    }
}
