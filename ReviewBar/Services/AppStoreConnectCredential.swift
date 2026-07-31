import Foundation

struct AppStoreConnectCredential: Codable, Equatable, Sendable {
    enum Scope: String, Codable, CaseIterable, Sendable {
        case team
        case individual

        var title: String {
            switch self {
            case .team: "Team key"
            case .individual: "Individual key"
            }
        }
    }

    let keyID: String
    let issuerID: String?
    let privateKeyPEM: String
    let scope: Scope

    nonisolated var isStructurallyValid: Bool {
        !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (scope == .individual || !(issuerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && privateKeyPEM.contains("BEGIN PRIVATE KEY")
            && privateKeyPEM.contains("END PRIVATE KEY")
    }
}
