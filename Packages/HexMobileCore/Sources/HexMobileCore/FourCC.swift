import Foundation

/// Renders an `OSStatus`-style error code as its four-character code, the
/// way Core Audio documents them.
///
/// `AVAudioEngine.start()` failed on a device with
/// `com.apple.coreaudio.avfaudio` code 2003329396, which is `'what'`, and
/// `setCategory` from the background with 560557684, which is `'!int'`
/// (1 Nov 2026). The number alone is unreadable in a log; the text names the
/// cause when it is printable.
public enum FourCC {
    /// The four characters of `code`, or `nil` when they are not all
    /// printable ASCII. Small codes such as 2, negative `OSStatus` values
    /// (their top byte is never ASCII) and anything above `UInt32.max` are
    /// plain numbers.
    public static func string(for code: Int) -> String? {
        guard let bits = UInt32(exactly: code) else { return nil }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: bits >> $0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
