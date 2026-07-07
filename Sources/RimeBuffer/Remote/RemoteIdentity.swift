import Foundation
import CryptoKit
import Security

/// This device's cryptographic identity for 隔空传字, plus the trusted-peer store.
///
/// Each Mac has a long-term Curve25519 (X25519) key pair — the PRIVATE half lives
/// in the Keychain, the PUBLIC half is the device's identity. Trust is
/// "trust on first use": when you tap 同意 to a pair request, the peer's public
/// key is remembered; from then on that Mac connects silently. No shared code is
/// ever typed — the pairing ACCEPT is the whole ceremony.
enum RemoteIdentity {
    private static let keyTag = "com.isaac.inputmethod.ETInput.remote.idkey"
    private static let trustKey = "remoteTrustedPeers"   // [pubKeyB64: name]

    // MARK: Long-term key pair (private key in Keychain)

    static let privateKey: Curve25519.KeyAgreement.PrivateKey = {
        if let data = keychainLoad(keyTag),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        keychainSave(keyTag, key.rawRepresentation)
        return key
    }()

    static var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    static var publicKeyB64: String { publicKeyData.base64EncodedString() }
    static var fingerprint: String { fingerprint(of: publicKeyData) }

    static func fingerprint(of pub: Data) -> String {
        SHA256.hash(data: pub).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Session key from static-static ECDH, freshened per connection by mixing in
    /// both sides' random session nonces (so a frame from an old session can't be
    /// replayed into a new one — it won't decrypt).
    static func sessionKey(peerPub: Data, nonceA: Data, nonceB: Data) -> SymmetricKey? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let salt = (nonceA.lexicographicallyPrecedes(nonceB) ? nonceA + nonceB : nonceB + nonceA)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt,
            sharedInfo: Data("etinput-remote-session-v1".utf8), outputByteCount: 32)
    }

    /// 4-digit short authentication string, identical on both Macs, shown during
    /// pairing so a careful user can confirm there's no man-in-the-middle.
    static func sas(with peerPub: Data) -> String {
        let pair = publicKeyData.lexicographicallyPrecedes(peerPub)
            ? publicKeyData + peerPub : peerPub + publicKeyData
        let n = SHA256.hash(data: pair).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%04d", n % 10000)
    }

    // MARK: Trust store (peer public keys; public data, kept in UserDefaults)

    static var trustedPeers: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: trustKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: trustKey) }
    }

    static func isTrusted(pub: Data) -> Bool { trustedPeers[pub.base64EncodedString()] != nil }

    static func trust(pub: Data, name: String) {
        var t = trustedPeers; t[pub.base64EncodedString()] = name; trustedPeers = t
    }

    static func untrust(pubB64: String) {
        var t = trustedPeers; t.removeValue(forKey: pubB64); trustedPeers = t
    }

    /// Fingerprints of trusted peers — lets us tell trusted vs unknown from a
    /// Bonjour TXT record BEFORE connecting (auto-connect only to trusted).
    static var trustedFingerprints: Set<String> {
        Set(trustedPeers.keys.compactMap { Data(base64Encoded: $0).map(fingerprint(of:)) })
    }

    // MARK: Keychain

    private static func keychainSave(_ tag: String, _ data: Data) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: tag]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainLoad(_ tag: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: tag,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (a, b) in zip(self, other) where a != b { return a < b }
        return count < other.count
    }
}
