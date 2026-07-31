import CryptoKit
import Foundation

actor JWTGenerator {
    struct Token: Sendable {
        let value: String
        let expiresAt: Date
    }

    private struct CachedToken: Sendable {
        let token: Token
        let scope: String
    }

    private let keyID: String
    private let issuerID: String?
    private let scopeType: AppStoreConnectCredential.Scope
    private let privateKey: P256.Signing.PrivateKey
    private let lifetime: TimeInterval
    private var cache: [String: CachedToken] = [:]

    init(credential: AppStoreConnectCredential, lifetime: TimeInterval = 600) throws {
        guard credential.isStructurallyValid, lifetime > 0, lifetime <= 1_200 else {
            throw AppError(kind: .invalidCredentials, message: "The App Store Connect credential format is invalid.")
        }
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: credential.privateKeyPEM)
        } catch {
            throw AppError(kind: .invalidCredentials, message: "The imported file is not a valid App Store Connect P-256 private key.")
        }
        keyID = credential.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        issuerID = credential.issuerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        scopeType = credential.scope
        self.lifetime = lifetime
    }

    func token(forGETPath path: String, now: Date = .now) throws -> Token {
        let scope = "GET \(path)"
        if let cached = cache[scope], cached.token.expiresAt.timeIntervalSince(now) > 60 {
            return cached.token
        }

        let issuedAt = Int(now.timeIntervalSince1970)
        let expiresAt = now.addingTimeInterval(lifetime)
        var payload: [String: Any] = [
            "iat": issuedAt,
            "exp": Int(expiresAt.timeIntervalSince1970),
            "aud": "appstoreconnect-v1",
            "scope": [scope]
        ]
        switch scopeType {
        case .team:
            guard let issuerID, !issuerID.isEmpty else {
                throw AppError(kind: .invalidCredentials, message: "A team key requires an issuer ID.")
            }
            payload["iss"] = issuerID
        case .individual:
            payload["sub"] = "user"
        }

        let header: [String: Any] = [
            "alg": "ES256",
            "kid": keyID,
            "typ": "JWT"
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = Base64URL.encode(headerData) + "." + Base64URL.encode(payloadData)
        guard let signingData = signingInput.data(using: .utf8) else {
            throw AppError(kind: .invalidCredentials, message: "ReviewBar could not encode an authentication token.")
        }
        let signature = try privateKey.signature(for: signingData)
        guard signature.rawRepresentation.count == 64 else {
            throw AppError(kind: .invalidCredentials, message: "ReviewBar produced an invalid authentication signature.")
        }
        let value = signingInput + "." + Base64URL.encode(signature.rawRepresentation)
        let token = Token(value: value, expiresAt: expiresAt)
        cache[scope] = CachedToken(token: token, scope: scope)
        return token
    }

    func invalidate(path: String? = nil) {
        if let path {
            cache["GET \(path)"] = nil
        } else {
            cache.removeAll(keepingCapacity: false)
        }
    }
}

