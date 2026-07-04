import InputMethodKit

/// The SOLE place text reaches the client. Every commit — ordinary, chord
/// release, or raw fallback — goes through here so ordering is guaranteed.
enum Delivery {
    static func insert(_ text: String, into client: IMKTextInput) {
        guard !text.isEmpty else { return }
        client.insertText(text as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
