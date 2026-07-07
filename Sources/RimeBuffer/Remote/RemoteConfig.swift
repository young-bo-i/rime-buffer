import Foundation

/// Non-secret settings for 隔空传字 (remote typing). Device identity keys and the
/// trusted-peer list live in RemoteIdentity (Keychain / vetted store); this only
/// holds the on/off switch and display name.
enum RemoteConfig {
    private static let d = UserDefaults.standard

    private static let deviceIDKey = "remoteDeviceID"
    private static let deviceNameKey = "remoteDeviceName"
    private static let enabledKey = "remoteTypingEnabled"

    /// Stable per-install id; used to de-dup discovery and pick a single
    /// connection initiator between two peers.
    static var deviceID: String {
        if let existing = d.string(forKey: deviceIDKey) { return existing }
        let fresh = UUID().uuidString
        d.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    /// Name shown on the other Mac. Defaults to the computer name.
    static var deviceName: String {
        get {
            if let n = d.string(forKey: deviceNameKey), !n.isEmpty { return n }
            return Host.current().localizedName ?? "Mac"
        }
        set { d.set(newValue, forKey: deviceNameKey) }
    }

    static var enabled: Bool {
        get { d.bool(forKey: enabledKey) }
        set { d.set(newValue, forKey: enabledKey) }
    }
}
