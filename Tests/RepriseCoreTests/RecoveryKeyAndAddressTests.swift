import CryptoKit
import XCTest
@testable import RepriseCore

final class RecoveryKeyAndAddressTests: XCTestCase {
    private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    func testRecoveryKeyRoundTripsAndCatchesTypingMistakes() throws {
        let key = SymmetricKey(data: Data((0..<32).map { UInt8($0 * 7 & 0xFF) }))
        let text = RecoveryKey.encode(key)
        XCTAssertTrue(text.hasPrefix("R1-"))
        XCTAssertEqual(text.split(separator: "-").count, 12)
        XCTAssertEqual(bytes(try RecoveryKey.decode(text)), bytes(key))
        // Lowercase, spaces instead of dashes and look-alike letters still read back.
        let relaxed = text.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(bytes(try RecoveryKey.decode(relaxed)), bytes(key))
        var changed = Array(text)
        changed[10] = changed[10] == "0" ? "2" : "0"
        XCTAssertThrowsError(try RecoveryKey.decode(String(changed))) { XCTAssertEqual($0 as? RecoveryKey.Failure, .checksum) }
        XCTAssertThrowsError(try RecoveryKey.decode(String(text.dropLast()))) { XCTAssertEqual($0 as? RecoveryKey.Failure, .malformed) }
        XCTAssertThrowsError(try RecoveryKey.decode("not a key")) { XCTAssertEqual($0 as? RecoveryKey.Failure, .malformed) }
    }

    func testBrowserAddressesKeepPagesAndDropSecrets() {
        XCTAssertEqual(BrowserAddress.sanitized(" https://user:pw@www.example.com/path?q=reprise&access_token=abc&code=1&page=2#section "),
                       "https://www.example.com/path?q=reprise&page=2")
        XCTAssertEqual(BrowserAddress.sanitized("https://example.com/reset?Session=1&SIG=2"), "https://example.com/reset")
        for other in ["file:///Users/me/notes.txt", "javascript:alert(1)", "about:blank", "chrome://settings", "not a url"] {
            XCTAssertNil(BrowserAddress.sanitized(other), other)
        }
        XCTAssertEqual(BrowserAddress.short("https://www.example.com/docs/page?x=1"), "example.com/docs/page")
        XCTAssertEqual(BrowserAddress.short("https://example.com/"), "example.com")
    }
}
