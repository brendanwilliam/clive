import CryptoKit
import Foundation
import Security

enum TLSIdentityError: LocalizedError {
    case keychain(OSStatus)
    case importFailed
    case opensslFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain operation failed (\(status))."
        case .importFailed: "The local TLS identity could not be imported."
        case .opensslFailed(let message): "TLS identity generation failed: \(message)"
        }
    }
}

/// Creates one self-signed identity for the user-scoped daemon and keeps its password in
/// Keychain. The certificate fingerprint is safe to place in a pairing QR payload; its key is not.
final class TLSIdentityStore {
    private let service = "com.iphoneterminal.daemon"
    private let account = "tls-identity-password"
    private let p12URL: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        p12URL = base.appending(path: "iphone-terminal/Identity/daemon.p12")
    }

    func loadOrCreate() throws -> SecIdentity {
        let password = try keychainPassword()
        if !FileManager.default.fileExists(atPath: p12URL.path) {
            try generateIdentity(password: password)
        }
        let data = try Data(contentsOf: p12URL)
        var result: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = (result as? [[String: Any]])?.first,
              let rawIdentity = item[kSecImportItemIdentity as String] else {
            throw TLSIdentityError.importFailed
        }
        let identity = rawIdentity as! SecIdentity
        return identity
    }

    func fingerprint(of identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw TLSIdentityError.importFailed
        }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    private func keychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) {
            return password
        }
        guard status == errSecItemNotFound else { throw TLSIdentityError.keychain(status) }
        let password = UUID().uuidString + UUID().uuidString
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TLSIdentityError.keychain(addStatus) }
        return password
    }

    private func generateIdentity(password: String) throws {
        let directory = p12URL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appending(path: "daemon-key.pem")
        let certificateURL = directory.appending(path: "daemon-cert.pem")
        defer {
            try? FileManager.default.removeItem(at: keyURL)
            try? FileManager.default.removeItem(at: certificateURL)
        }
        try runOpenSSL(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", keyURL.path, "-out", certificateURL.path, "-days", "365", "-subj", "/CN=iphone-terminal"])
        try runOpenSSL(["pkcs12", "-export", "-out", p12URL.path, "-inkey", keyURL.path, "-in", certificateURL.path, "-passout", "pass:\(password)"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw TLSIdentityError.opensslFailed(message)
        }
    }
}
