import Foundation
import IPhoneTerminalCore
import Security

struct PairedMacStore {
    private let service = "com.iphoneterminal.paired-macs"
    func load() throws -> [PairedMac] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = value as? Data else { throw StoreError.keychain(status) }
        return try JSONDecoder().decode([PairedMac].self, from: data)
    }
    func save(_ records: [PairedMac]) throws {
        let data = try JSONEncoder().encode(records)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { var add = query; values.forEach { add[$0.key] = $0.value }; guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw StoreError.keychain(status) } }
        else if status != errSecSuccess { throw StoreError.keychain(status) }
    }
    enum StoreError: Error { case keychain(OSStatus) }
}
