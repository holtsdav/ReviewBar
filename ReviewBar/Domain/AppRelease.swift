import Foundation
import SwiftUI

struct AppRelease: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let version: String
    let platform: Platform
    let state: ReleaseState
    let createdDate: Date?
    let submittedDate: Date?
    let earliestReleaseDate: Date?
    let releaseType: String?
    var selectedBuildID: String? = nil
    var reviewSubmissionState: String? = nil

    enum Platform: String, Codable, Hashable, Sendable {
        case iOS = "IOS"
        case macOS = "MAC_OS"
        case tvOS = "TV_OS"
        case visionOS = "VISION_OS"
        case unknown

        var label: String {
            switch self {
            case .iOS: "iOS"
            case .macOS: "macOS"
            case .tvOS: "tvOS"
            case .visionOS: "visionOS"
            case .unknown: "Other"
            }
        }

        init(apiValue: String) {
            self = Self(rawValue: apiValue) ?? .unknown
        }
    }
}

struct ReleaseState: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let accepted = Self(rawValue: "ACCEPTED")
    static let prepareForSubmission = Self(rawValue: "PREPARE_FOR_SUBMISSION")
    static let readyForReview = Self(rawValue: "READY_FOR_REVIEW")
    static let waitingForReview = Self(rawValue: "WAITING_FOR_REVIEW")
    static let waitingForExportCompliance = Self(rawValue: "WAITING_FOR_EXPORT_COMPLIANCE")
    static let inReview = Self(rawValue: "IN_REVIEW")
    static let pendingDeveloperRelease = Self(rawValue: "PENDING_DEVELOPER_RELEASE")
    static let processingForDistribution = Self(rawValue: "PROCESSING_FOR_DISTRIBUTION")
    static let readyForDistribution = Self(rawValue: "READY_FOR_DISTRIBUTION")
    static let rejected = Self(rawValue: "REJECTED")
    static let developerRejected = Self(rawValue: "DEVELOPER_REJECTED")
    static let metadataRejected = Self(rawValue: "METADATA_REJECTED")
    static let invalidBinary = Self(rawValue: "INVALID_BINARY")
    static let pendingAppleRelease = Self(rawValue: "PENDING_APPLE_RELEASE")
    static let replacedWithNewVersion = Self(rawValue: "REPLACED_WITH_NEW_VERSION")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(apiValue: String) {
        self.rawValue = apiValue
    }

    var title: String {
        switch rawValue {
        case Self.accepted.rawValue: "Accepted"
        case Self.prepareForSubmission.rawValue: "Prepare for Submission"
        case Self.readyForReview.rawValue: "Ready for Review"
        case Self.waitingForReview.rawValue: "Waiting for Review"
        case Self.waitingForExportCompliance.rawValue: "Waiting for Export Compliance"
        case Self.inReview.rawValue: "In Review"
        case Self.pendingDeveloperRelease.rawValue: "Pending Developer Release"
        case Self.processingForDistribution.rawValue: "Processing for Distribution"
        case Self.readyForDistribution.rawValue: "Ready for Distribution"
        case Self.rejected.rawValue: "Rejected"
        case Self.developerRejected.rawValue: "Developer Rejected"
        case Self.metadataRejected.rawValue: "Metadata Rejected"
        case Self.invalidBinary.rawValue: "Invalid Binary"
        case Self.pendingAppleRelease.rawValue: "Pending Apple Release"
        case Self.replacedWithNewVersion.rawValue: "Replaced by New Version"
        default: "Unknown (\(rawValue))"
        }
    }

    var symbol: String {
        switch rawValue {
        case Self.waitingForReview.rawValue, Self.readyForReview.rawValue: "clock"
        case Self.inReview.rawValue, Self.processingForDistribution.rawValue: "hourglass"
        case Self.readyForDistribution.rawValue, Self.accepted.rawValue: "checkmark.circle.fill"
        case Self.pendingDeveloperRelease.rawValue, Self.pendingAppleRelease.rawValue: "pause.circle.fill"
        case Self.rejected.rawValue, Self.developerRejected.rawValue,
             Self.metadataRejected.rawValue, Self.invalidBinary.rawValue: "exclamationmark.triangle.fill"
        case Self.replacedWithNewVersion.rawValue: "minus.circle"
        case Self.prepareForSubmission.rawValue: "pencil.circle"
        default: "questionmark.circle"
        }
    }

    var tint: Color {
        switch rawValue {
        case Self.readyForDistribution.rawValue, Self.accepted.rawValue: .green
        case Self.inReview.rawValue, Self.processingForDistribution.rawValue: .blue
        case Self.waitingForReview.rawValue, Self.readyForReview.rawValue,
             Self.pendingDeveloperRelease.rawValue, Self.pendingAppleRelease.rawValue,
             Self.waitingForExportCompliance.rawValue: .orange
        case Self.rejected.rawValue, Self.developerRejected.rawValue,
             Self.metadataRejected.rawValue, Self.invalidBinary.rawValue: .red
        default: .secondary
        }
    }

    var isReviewLifecycle: Bool {
        [Self.readyForReview, .waitingForReview, .inReview, .pendingDeveloperRelease,
         .processingForDistribution, .readyForDistribution, .rejected, .developerRejected,
         .metadataRejected, .invalidBinary, .pendingAppleRelease].contains(self)
    }
}
