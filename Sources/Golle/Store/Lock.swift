import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// How a password-locked document is encrypted.
///
/// The key is derived from the password with PBKDF2-SHA256 and a random salt. Every file in the package
/// (`database.sqlite` and each attachment) is sealed with AES-256-GCM, which also detects tampering.
/// `lock.json` holds the salt, the round count and a sealed check value, so a wrong password is told
/// apart from a damaged file. The password itself is never stored.
struct LockInfo: Codable, Equatable {
    static let fileName = "lock.json"
    static let defaultRounds = 600_000

    var version = 1
    /// Names the Keychain item that remembers the key for Touch ID.
    var id = UUID()
    var salt: Data
    var rounds: Int
    var check: Data
    var hint: String?

    /// New lock info for a password; returns the key too.
    static func create(password: String, hint: String?, rounds: Int = defaultRounds) throws -> (LockInfo, SymmetricKey) {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw LockError.random }
        let key = try deriveKey(password, salt: salt, rounds: rounds)
        let check = try seal(Data("golle".utf8), with: key)
        let trimmedHint = hint?.trimmingCharacters(in: .whitespaces)
        return (LockInfo(salt: salt, rounds: rounds, check: check, hint: trimmedHint?.isEmpty == false ? trimmedHint : nil), key)
    }

    /// The key for a password, or nil when the password is wrong.
    func key(for password: String) -> SymmetricKey? {
        guard let key = try? Self.deriveKey(password, salt: salt, rounds: rounds) else { return nil }
        return verifies(key) ? key : nil
    }

    func verifies(_ key: SymmetricKey) -> Bool {
        (try? Self.open(check, with: key)) == Data("golle".utf8)
    }

    static func deriveKey(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            passwordBytes.withUnsafeBufferPointer { pw in
                pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { pwChars in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwChars, pw.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                         &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw LockError.derive }
        return SymmetricKey(data: derived)
    }

    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw LockError.seal }
        return combined
    }

    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

enum LockError: LocalizedError {
    case random, derive, seal, wrongPassword, damaged

    var errorDescription: String? {
        switch self {
        case .random, .derive, .seal: "Encryption failed."
        case .wrongPassword: "The password is incorrect."
        case .damaged: "The database could not be decrypted. It may be damaged."
        }
    }
}

/// Remembers a document's key in the login Keychain so Touch ID can unlock it.
///
/// The data-protection Keychain (with biometric access control) needs a provisioning profile, which a
/// build without Xcode doesn't have. So Touch ID is asked first, with LocalAuthentication, and the key
/// sits in the login Keychain, where its access list allows only this app's code signature.
enum KeyStore {
    private static let service = "com.iappyx.Golle.document-key"

    static var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func save(_ key: SymmetricKey, for id: UUID) {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Golle database key"
        SecItemAdd(item as CFDictionary, nil)
    }

    static func has(_ id: UUID) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }

    /// Asks for Touch ID, then reads the key.
    static func load(_ id: UUID, reason: String) async -> SymmetricKey? {
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }
}
