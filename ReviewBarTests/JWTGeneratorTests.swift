import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

struct JWTGeneratorTests {
    @Test("Team token uses issuer and a raw ES256 signature")
    func teamToken() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "TESTKEY123",
            issuerID: "00000000-0000-0000-0000-000000000000",
            privateKeyPEM: privateKey.pemRepresentation,
            scope: .team
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try await JWTGenerator(credential: credential).token(forGETPath: "/v1/apps", now: now)
        let parts = token.value.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let payload = try decodedJSON(parts[1])
        #expect(payload["iss"] as? String == credential.issuerID)
        #expect(payload["sub"] == nil)
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
        #expect((payload["exp"] as? Int ?? 0) - (payload["iat"] as? Int ?? 0) <= 1_200)

        let signatureData = try #require(Base64URL.decode(parts[2]))
        #expect(signatureData.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signedData = try #require("\(parts[0]).\(parts[1])".data(using: .utf8))
        #expect(privateKey.publicKey.isValidSignature(signature, for: signedData))
        #expect(token.value.contains("=") == false)
    }

    @Test("Individual token uses sub user and omits issuer")
    func individualToken() async throws {
        let key = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "PERSONAL1",
            issuerID: nil,
            privateKeyPEM: key.pemRepresentation,
            scope: .individual
        )
        let token = try await JWTGenerator(credential: credential).token(forGETPath: "/v1/builds")
        let parts = token.value.split(separator: ".").map(String.init)
        let payload = try decodedJSON(parts[1])
        #expect(payload["sub"] as? String == "user")
        #expect(payload["iss"] == nil)
        #expect(payload["scope"] as? [String] == ["GET /v1/builds"])
    }

    @Test("Mutation tokens omit the GET-only scope claim")
    func mutationTokenIsUnscoped() async throws {
        let key = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "TEAMKEY1",
            issuerID: "00000000-0000-0000-0000-000000000000",
            privateKeyPEM: key.pemRepresentation,
            scope: .team
        )
        let token = try await JWTGenerator(credential: credential).token(
            method: "POST",
            path: "/v1/analyticsReportRequests",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let parts = token.value.split(separator: ".").map(String.init)
        let payload = try decodedJSON(parts[1])
        #expect(payload["iss"] as? String == credential.issuerID)
        #expect(payload["scope"] == nil)
    }

    @Test("Token lifetime over Apple's limit is rejected")
    func excessiveLifetime() {
        let key = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "TEST",
            issuerID: nil,
            privateKeyPEM: key.pemRepresentation,
            scope: .individual
        )
        #expect(throws: AppError.self) {
            _ = try JWTGenerator(credential: credential, lifetime: 1_201)
        }
    }

    @Test("Concurrent requests reuse the same unexpired path-scoped token")
    func concurrentReuse() async throws {
        let key = P256.Signing.PrivateKey()
        let credential = AppStoreConnectCredential(
            keyID: "PERSONAL1",
            issuerID: nil,
            privateKeyPEM: key.pemRepresentation,
            scope: .individual
        )
        let generator = try JWTGenerator(credential: credential)
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await generator.token(forGETPath: "/v1/apps").value
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(values).count == 1)
    }

    private func decodedJSON(_ encoded: String) throws -> [String: Any] {
        let data = try #require(Base64URL.decode(encoded))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
