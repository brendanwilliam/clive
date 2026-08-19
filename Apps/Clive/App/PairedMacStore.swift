import Foundation
import CliveCore
import Security

struct PairedMacStore {
    private let service = "com.clive.paired-macs"
    func load() throws -> [PairedMac] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "records", kSecReturnData as String: true]
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = value as? Data else { throw StoreError.keychain(status) }
        return try JSONDecoder().decode([PairedMac].self, from: data)
    }
    func save(_ records: [PairedMac]) throws {
        let data = try JSONEncoder().encode(records)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "records"]
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { var add = query; values.forEach { add[$0.key] = $0.value }; let addStatus = SecItemAdd(add as CFDictionary, nil); guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) } }
        else if status != errSecSuccess { throw StoreError.keychain(status) }
    }
    func upsert(_ record: PairedMac) throws {
        var records = try load(); records.removeAll { $0.id == record.id || $0.serviceID == record.serviceID }; records.append(record); try save(records)
    }
    enum StoreError: Error { case keychain(OSStatus) }
}
