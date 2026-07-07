import Foundation
import CryptoKit

/// This device's cryptographic identity for 隔空传字, plus the trusted-peer store.
///
/// Each Mac has a long-term Curve25519 (X25519) key pair — the PRIVATE half is
/// stored in a 0600 file under the app's user dir, the PUBLIC half is the
/// device's identity. Trust is "trust on first use": when you tap 同意 to a pair
/// request, the peer's public key is remembered; from then on that Mac connects
/// silently. No shared code is ever typed — the pairing ACCEPT is the ceremony.
///
/// (We deliberately DON'T use the login Keychain: ETInput is ad-hoc signed, so
/// every rebuild/auto-update changes the code signature and the Keychain ACL
/// would re-prompt for the password on every launch. A 0600 file is the right
/// store for a random 256-bit key here.)
enum RemoteIdentity {
    private static let trustKey = "remoteTrustedPeers"   // [pubKeyB64: name]

    private static var keyFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/RimeBuffer/remote_identity.key")
    }

    // MARK: Long-term key pair (private key in a 0600 file)

    static let privateKey: Curve25519.KeyAgreement.PrivateKey = {
        if let data = try? Data(contentsOf: keyFileURL),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        saveKey(key.rawRepresentation)
        return key
    }()

    private static func saveKey(_ data: Data) {
        let url = keyFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

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

}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (a, b) in zip(self, other) where a != b { return a < b }
        return count < other.count
    }
}
