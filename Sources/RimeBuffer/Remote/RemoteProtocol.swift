import Foundation
import CryptoKit
import Security

// MARK: - Crypto helpers

enum RemoteCrypto {
    static func seal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(plaintext, using: key).combined
    }
    static func open(_ sealed: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
    static func randomNonce(_ count: Int = 16) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Messages

/// Plaintext handshake sent first on every connection. Public keys ARE public,
/// so this is not secret; the ECDH shared secret (which an eavesdropper can't
/// compute) is what secures everything after.
struct HelloMessage: Codable {
    let deviceID: String
    let name: String
    let pubKey: String   // base64 X25519 public key
    let nonce: String    // base64 per-connection random (freshens the session key)
}

/// Everything after the handshake, AES-GCM sealed under the session key. `seq`
/// is a per-sender monotonic counter; the receiver rejects non-increasing values
/// so a captured frame can't be replayed within a session.
struct SealedMessage: Codable {
    enum Kind: String, Codable {
        case pairRequest    // "may I pair with you?"
        case pairAccept     // "同意" — you're now trusted
        case pairReject     // "拒绝"
        case text           // committed text to type on the peer
        case heartbeat      // liveness
    }
    let kind: Kind
    let seq: UInt64
    var text: String?
}

// MARK: - Framing

enum RemoteFrameType: UInt8 { case hello = 0, sealed = 1 }

struct RawFrame {
    let type: RemoteFrameType
    let payload: Data
}

/// Wire format per frame: 4-byte big-endian payload length + 1 type byte +
/// payload. The decoder accumulates bytes and yields whole raw frames; the
/// caller decodes hello (plaintext) or opens sealed frames with the session key.
enum RemoteFrame {
    static let maxFrameBytes = 1 << 20   // 1 MiB sanity cap

    static func encodeHello(_ h: HelloMessage) -> Data? {
        guard let json = try? JSONEncoder().encode(h) else { return nil }
        return frame(.hello, json)
    }

    static func encodeSealed(_ m: SealedMessage, key: SymmetricKey) -> Data? {
        guard let json = try? JSONEncoder().encode(m),
              let sealed = RemoteCrypto.seal(json, key: key) else { return nil }
        return frame(.sealed, sealed)
    }

    private static func frame(_ type: RemoteFrameType, _ payload: Data) -> Data? {
        guard payload.count <= maxFrameBytes else { return nil }
        var out = Data(capacity: payload.count + 5)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    /// Streaming decoder. Feed received bytes; returns whole raw frames as they
    /// complete. Returns nil on a protocol violation (bad length / unknown type)
    /// so the caller drops the connection.
    final class Decoder {
        private var buffer = Data()

        func feed(_ data: Data) -> [RawFrame]? {
            buffer.append(data)
            var frames: [RawFrame] = []
            while buffer.count >= 5 {
                let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if len == 0 || Int(len) > RemoteFrame.maxFrameBytes { return nil }
                guard buffer.count >= 5 + Int(len) else { break }
                guard let type = RemoteFrameType(rawValue: buffer[buffer.startIndex + 4]) else { return nil }
                let start = buffer.startIndex + 5
                let payload = buffer.subdata(in: start ..< start + Int(len))
                buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 5 + Int(len))
                frames.append(RawFrame(type: type, payload: payload))
            }
            return frames
        }
    }
}
