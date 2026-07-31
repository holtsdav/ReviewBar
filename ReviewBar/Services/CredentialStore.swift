import Foundation
import Security

protocol CredentialStoring: Sendable {
    func load() async throws -> AppStoreConnectCredential?
    func save(_ credential: AppStoreConnectCredential) async throws
    func delete() async throws
}

actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account = "app-store-connect-credential"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.reviewbar.ReviewBar") {
        self.service = service
    }

    func load() throws -> AppStoreConnectCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        do {
            return try JSONDecoder().decode(AppStoreConnectCredential.self, from: data)
        } catch {
            throw AppError(kind: .secureStorage, message: "Saved credentials are damaged. Remove the connection and import your key again.")
        }
    }

    func save(_ credential: AppStoreConnectCredential) throws {
        let data = try JSONEncoder().encode(credential)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw keychainError(updateStatus) }
        } else if addStatus != errSecSuccess {
            throw keychainError(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
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
        AppError(kind: .secureStorage, message: "ReviewBar could not access the secure credential store (code \(status)).")
    }
}

actor MemoryCredentialStore: CredentialStoring {
    private var credential: AppStoreConnectCredential?

    init(credential: AppStoreConnectCredential? = nil) {
        self.credential = credential
    }

    func load() -> AppStoreConnectCredential? { credential }
    func save(_ credential: AppStoreConnectCredential) { self.credential = credential }
    func delete() { credential = nil }
}
