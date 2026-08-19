import Foundation
import CliveCore
import Security

public final class RendezvousKeyStore: @unchecked Sendable {
    private struct StoredKeys: Codable { let agreement: Data; let signing: Data }
    private let service: String
    private let account = "rendezvous-v1"

    public init(service: String) { self.service = service }

    public func loadOrCreate() throws -> RendezvousKeyPair {
        let query = baseQuery(returnData: true)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let stored = try JSONDecoder().decode(StoredKeys.self, from: data)
            return try RendezvousKeyPair(agreementPrivateKey: stored.agreement, signingPrivateKey: stored.signing)
        }
        guard status == errSecItemNotFound else { throw AppleIdentityError.keychain(status) }
        let keys = RendezvousKeyPair()
        let data = try JSONEncoder().encode(StoredKeys(agreement: keys.agreementPrivateKey, signing: keys.signingPrivateKey))
        var add = baseQuery(returnData: false)
        add[kSecValueData as String] = data
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecUseDataProtectionKeychain as String] = true
        #endif
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AppleIdentityError.keychain(addStatus) }
        return keys
    }

    private func baseQuery(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if returnData { query[kSecReturnData as String] = true }
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
