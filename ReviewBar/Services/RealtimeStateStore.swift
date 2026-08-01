import Foundation
import Security

protocol RealtimeStateStoring: Sendable {
    func load() async throws -> RealtimeInstallation?
    func save(_ installation: RealtimeInstallation) async throws
    func delete() async throws
}

actor KeychainRealtimeStateStore: RealtimeStateStoring {
    private let service: String
    private let account = "notification-relay-installation"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.reviewbar.ReviewBar") {
        self.service = service
    }

    func load() throws -> RealtimeInstallation? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        do {
            return try JSONDecoder().decode(RealtimeInstallation.self, from: data)
        } catch {
            throw AppError(kind: .secureStorage, message: "Saved real-time notification settings are damaged. Disable notifications and try again.")
        }
    }

    func save(_ installation: RealtimeInstallation) throws {
        let data = try JSONEncoder().encode(installation)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func keychainError(_ status: OSStatus) -> AppError {
        AppError(kind: .secureStorage, message: "ReviewBar couldn't access notification credentials in the Keychain (code \(status)).")
    }
}

actor MemoryRealtimeStateStore: RealtimeStateStoring {
    private var installation: RealtimeInstallation?

    init(installation: RealtimeInstallation? = nil) { self.installation = installation }
    func load() -> RealtimeInstallation? { installation }
    func save(_ installation: RealtimeInstallation) { self.installation = installation }
    func delete() { installation = nil }
}
