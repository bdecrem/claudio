import Foundation
import CryptoKit
import Security
import os

private let log = Logger(subsystem: "com.claudio.app", category: "DeviceIdentity")

/// Manages Ed25519 device identity for WebSocket authentication.
/// Generates a keypair on first use, persists private key in Keychain.
final class DeviceIdentity {
    static let shared = DeviceIdentity()

    private let keyTag = "com.claudio.device-key"
    private let deviceTokenKey = "com.claudio.device-token"

    private var _privateKey: Curve25519.Signing.PrivateKey?

    private init() {
        _privateKey = loadOrCreatePrivateKey()
    }

    // MARK: - Public

    var publicKey: Curve25519.Signing.PublicKey {
        privateKey.publicKey
    }

    /// SHA256(publicKeyBytes) as hex — stable device identifier
    var deviceId: String {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Base64url-encoded public key bytes (raw representation, 32 bytes)
    var publicKeyBase64URL: String {
        publicKey.rawRepresentation.base64URLEncoded()
    }

    /// Server-issued device token, persisted in Keychain
    var deviceToken: String? {
        get { UserDefaults.standard.string(forKey: deviceTokenKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: deviceTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: deviceTokenKey)
            }
        }
    }

    /// Sign the connect challenge per the OpenClaw WS protocol
    func signChallenge(nonce: String, token: String, signedAt: Int64) -> String? {
        let payload = "v2|\(deviceId)|openclaw-ios|ui|operator|operator.read,operator.write|\(signedAt)|\(token)|\(nonce)"
        guard let data = payload.data(using: .utf8) else { return nil }

        do {
            let signature = try privateKey.signature(for: data)
            return signature.base64URLEncoded()
        } catch {
            log.error("Failed to sign challenge: \(error)")
            return nil
        }
    }

    // MARK: - Private

    private var privateKey: Curve25519.Signing.PrivateKey {
        if let key = _privateKey { return key }
        let key = loadOrCreatePrivateKey()
        _privateKey = key
        return key
    }

    private func loadOrCreatePrivateKey() -> Curve25519.Signing.PrivateKey {
        if let existing = loadFromKeychain() {
            log.info("Loaded existing device key from Keychain")
            return existing
        }

        let newKey = Curve25519.Signing.PrivateKey()
        saveToKeychain(newKey)
        log.info("Generated new device key, deviceId=\(self.deviceId)")
        return newKey
    }

    private func loadFromKeychain() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func saveToKeychain(_ key: Curve25519.Signing.PrivateKey) {
        // Delete any existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Failed to save device key to Keychain: \(status)")
        }
    }
}

// MARK: - Base64URL encoding

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

extension ContiguousBytes {
    func base64URLEncoded() -> String {
        var data = Data()
        withUnsafeBytes { data.append(contentsOf: $0) }
        return data.base64URLEncoded()
    }
}
