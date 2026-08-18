import CryptoKit
import Foundation
import Security

enum TLSIdentityError: LocalizedError {
    case keychain(OSStatus), importFailed, opensslFailed(String)
    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain operation failed (\(status))."
        case .importFailed: "The local TLS identity could not be imported."
        case .opensslFailed(let message): "TLS identity generation failed: \(message)"
        }
    }
}

/// macOS stores an encrypted PKCS#12 identity owner-only; its random password is device-only Keychain data.
final class TLSIdentityStore {
    private let p12URL: URL
    private let passwordURL: URL

    init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        let base = baseURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "iphone-terminal")
        p12URL = base.appending(path: "Identity/daemon.p12")
        passwordURL = base.appending(path: "Identity/daemon.password")
    }
    func loadOrCreate() throws -> SecIdentity {
        let password = try keychainPassword()
        if !FileManager.default.fileExists(atPath: p12URL.path) { try generateIdentity(password: password) }
        let data = try Data(contentsOf: p12URL); var result: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &result)
        guard status == errSecSuccess, let item = (result as? [[String: Any]])?.first, let rawIdentity = item[kSecImportItemIdentity as String] else { throw TLSIdentityError.importFailed }
        return rawIdentity as! SecIdentity
    }
    func certificateData(of identity: SecIdentity) throws -> Data {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw TLSIdentityError.importFailed }
        return SecCertificateCopyData(certificate) as Data
    }
    func fingerprint(of identity: SecIdentity) throws -> String { SHA256.hash(data: try certificateData(of: identity)).map { String(format: "%02x", $0) }.joined() }
    private func keychainPassword() throws -> String {
        if let data = try? Data(contentsOf: passwordURL), let password = String(data: data, encoding: .utf8), !password.isEmpty { return password }
        let password = UUID().uuidString + UUID().uuidString
        try FileManager.default.createDirectory(at: passwordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(password.utf8).write(to: passwordURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
        return password
    }
    private func generateIdentity(password: String) throws {
        let directory = p12URL.deletingLastPathComponent(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appending(path: "daemon-key.pem"); let certificateURL = directory.appending(path: "daemon-cert.pem")
        defer { try? FileManager.default.removeItem(at: keyURL); try? FileManager.default.removeItem(at: certificateURL) }
        try runOpenSSL(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyURL.path])
        try runOpenSSL(["req", "-x509", "-new", "-key", keyURL.path, "-out", certificateURL.path, "-days", "3650", "-subj", "/CN=iphone-terminal"])
        try runOpenSSL(["pkcs12", "-export", "-name", "iphone-terminal", "-out", p12URL.path, "-inkey", keyURL.path, "-in", certificateURL.path, "-passout", "pass:\(password)"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
    }
    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); process.arguments = arguments
        let errors = Pipe(); process.standardError = errors; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TLSIdentityError.opensslFailed(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error") }
    }
}
