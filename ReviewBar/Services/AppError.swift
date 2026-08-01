import Foundation

struct AppError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case noCredentials
        case invalidCredentials
        case revokedCredential
        case insufficientPermission
        case offline
        case rateLimited(retryAfter: TimeInterval?)
        case appleUnavailable
        case malformedResponse
        case fileImport
        case secureStorage
        case other
    }

    let kind: Kind
    let message: String
    /// True only when Apple returned an authoritative non-success HTTP status,
    /// proving a mutating request was rejected rather than leaving its outcome
    /// ambiguous through transport loss or response-decoding failure.
    let requestWasRejected: Bool

    init(kind: Kind, message: String, requestWasRejected: Bool = false) {
        self.kind = kind
        self.message = message
        self.requestWasRejected = requestWasRejected
    }

    var title: String {
        switch kind {
        case .noCredentials: "No Credentials"
        case .invalidCredentials: "Invalid Credentials"
        case .revokedCredential: "Credential Revoked"
        case .insufficientPermission: "Permission Required"
        case .offline: "You’re Offline"
        case .rateLimited: "Refresh Paused"
        case .appleUnavailable: "Apple Unavailable"
        case .malformedResponse: "Unexpected Apple Response"
        case .fileImport: "Couldn’t Import Key"
        case .secureStorage: "Secure Storage Issue"
        case .other: "Couldn’t Refresh"
        }
    }

    static func map(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is DecodingError {
            return AppError(
                kind: .malformedResponse,
                message: "Apple returned data ReviewBar could not understand. Your cached data is still available."
            )
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return AppError(kind: .offline, message: "ReviewBar could not reach Apple. Check your connection and try again.")
            default:
                break
            }
        }
        return AppError(kind: .other, message: "ReviewBar couldn’t complete that request. Please try again.")
    }
}
