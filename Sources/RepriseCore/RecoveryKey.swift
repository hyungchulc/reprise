import CryptoKit
import Foundation

/// The library's master key written out for a password manager or paper. Anyone holding it and
/// the library files can read every memory, so Reprise shows it only after the Mac's owner
/// authenticates. Base32 without I, L, O and U, plus a checksum that catches typing mistakes.
public enum RecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let prefix = "R1"

    public enum Failure: LocalizedError, Equatable {
        case malformed, checksum, wrongLibrary
        public var errorDescription: String? {
            switch self {
            case .malformed: return "That is not a Reprise recovery key. It starts with R1 and has 11 groups."
            case .checksum: return "The recovery key has a typing mistake. Check each group and try again."
            case .wrongLibrary: return "This recovery key belongs to a different library."
            }
        }
    }

    public static func encode(_ key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Array($0) }
        let payload = bytes + Array(SHA256.hash(data: bytes).prefix(2))
        var bits = 0, value = 0, characters: [Character] = []
        for byte in payload {
            value = ((value << 8) | Int(byte)) & 0xFFFF; bits += 8
            while bits >= 5 { characters.append(alphabet[(value >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { characters.append(alphabet[(value << (5 - bits)) & 31]) }
        let groups = stride(from: 0, to: characters.count, by: 5).map { String(characters[$0..<min($0 + 5, characters.count)]) }
        return ([prefix] + groups).joined(separator: "-")
    }

    public static func decode(_ text: String) throws -> SymmetricKey {
        // Look-alike letters read as the digits they resemble, the prefix included.
        var cleaned = String(text.uppercased().compactMap { character -> Character? in
            switch character {
            case "-": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return character.isWhitespace ? nil : character
            }
        })
        guard cleaned.hasPrefix(prefix) else { throw Failure.malformed }
        cleaned.removeFirst(prefix.count)
        var bits = 0, value = 0, bytes: [UInt8] = []
        for character in cleaned {
            guard let digit = alphabet.firstIndex(of: character) else { throw Failure.malformed }
            value = ((value << 5) | digit) & 0xFFFF; bits += 5
            if bits >= 8 { bytes.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        guard bytes.count == 34 else { throw Failure.malformed }
        let key = Array(bytes.prefix(32))
        guard Array(SHA256.hash(data: key).prefix(2)) == Array(bytes.suffix(2)) else { throw Failure.checksum }
        return SymmetricKey(data: key)
    }
}
