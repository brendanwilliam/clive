import Foundation
import CliveSecurity
import Security
import UIKit

struct IPhoneIdentity: @unchecked Sendable {
    let deviceID: String
    let displayName: String
    let identity: SecIdentity
    let certificate: Data
}

struct IPhoneIdentityProvider {
    private let service = "com.clive.iphone-identity"
    @MainActor func loadOrCreate() throws -> IPhoneIdentity {
        let store = AppleIdentityStore(label: "com.clive.iphone.tls", commonName: "clive iPhone")
        let identity = try store.loadOrCreate()
        return IPhoneIdentity(deviceID: try deviceID(), displayName: UIDevice.current.name, identity: identity, certificate: try store.certificateData(of: identity))
    }

    private func deviceID() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device-id", kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) { return value }
        guard status == errSecItemNotFound else { throw AppleIdentityError.keychain(status) }
        let value = UUID().uuidString.lowercased()
        var add = query; add.removeValue(forKey: kSecReturnData as String)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AppleIdentityError.keychain(addStatus) }
        return value
    }
}
