import Crypto
import Foundation
import IPhoneTerminalCore
import Security
import X509

public enum AppleIdentityError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case identityUnavailable
    case certificateCreation

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain identity operation failed (\(status))."
        case .identityUnavailable: "The TLS identity is unavailable."
        case .certificateCreation: "The self-signed certificate could not be created."
        }
    }
}

/// Creates a non-exported P-256 key and self-signed certificate that Security.framework can
/// resolve as a SecIdentity. The key and certificate never leave the Keychain.
public final class AppleIdentityStore: @unchecked Sendable {
    public let label: String
    private let commonName: String
    private let usesDataProtectionKeychain: Bool

    public init(label: String, commonName: String, usesDataProtectionKeychain: Bool? = nil) {
        self.label = label
        self.commonName = commonName
        #if os(iOS)
        self.usesDataProtectionKeychain = usesDataProtectionKeychain ?? true
        #else
        self.usesDataProtectionKeychain = usesDataProtectionKeychain ?? false
        #endif
    }

    public func loadOrCreate() throws -> SecIdentity {
        if let identity = try load() { return identity }
        try create()
        guard let identity = try load() else { throw AppleIdentityError.identityUnavailable }
        return identity
    }

    public func load() throws -> SecIdentity? {
        var certificateQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if usesDataProtectionKeychain { certificateQuery[kSecUseDataProtectionKeychain as String] = true }
        var certificateResult: CFTypeRef?
        let certificateStatus = SecItemCopyMatching(certificateQuery as CFDictionary, &certificateResult)
        if certificateStatus == errSecItemNotFound { return nil }
        guard certificateStatus == errSecSuccess, let certificateResult else { throw AppleIdentityError.keychain(certificateStatus) }
        let expectedData = SecCertificateCopyData(certificateResult as! SecCertificate) as Data
        var identityQuery: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        if usesDataProtectionKeychain { identityQuery[kSecUseDataProtectionKeychain as String] = true }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else { throw AppleIdentityError.keychain(status) }
        return identities.first { identity in
            var certificate: SecCertificate?
            return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess && certificate.map { SecCertificateCopyData($0) as Data == expectedData } == true
        }
    }

    public func certificateData(of identity: SecIdentity) throws -> Data {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw AppleIdentityError.identityUnavailable }
        return SecCertificateCopyData(certificate) as Data
    }

    public func fingerprint(of identity: SecIdentity) throws -> String {
        Fingerprint.sha256(of: try certificateData(of: identity))
    }

    private func create() throws {
        let tag = Data(label.utf8)
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String: label,
        ]
        if usesDataProtectionKeychain { privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        if usesDataProtectionKeychain { attributes[kSecUseDataProtectionKeychain as String] = true }
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
            if let keyError { throw keyError.takeRetainedValue() }
            throw AppleIdentityError.certificateCreation
        }
        do {
            let privateKey = try Certificate.PrivateKey(secKey)
            let name = try DistinguishedName { CommonName(commonName) }
            let now = Date()
            let certificate = try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: privateKey.publicKey,
                notValidBefore: now - 300,
                notValidAfter: now + (10 * 365 * 24 * 60 * 60),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                },
                issuerPrivateKey: privateKey
            )
            let secCertificate = try SecCertificate.makeWithCertificate(certificate)
            var add: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
                kSecValueRef as String: secCertificate,
            ]
            if usesDataProtectionKeychain { add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; add[kSecUseDataProtectionKeychain as String] = true }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw AppleIdentityError.keychain(status) }
        } catch {
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
            throw error
        }
    }
}
