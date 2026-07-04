import Foundation

/// Minimal file logger at ~/rimebuffer.log so behaviour can be inspected
/// without seeing the UI. Cheap; fine to leave on during bring-up.
enum IMELog {
    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("rimebuffer.log")

    static func write(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func reset(_ header: String) {
        try? "\(Date().timeIntervalSince1970) \(header)\n".data(using: .utf8)?.write(to: url)
    }
}
