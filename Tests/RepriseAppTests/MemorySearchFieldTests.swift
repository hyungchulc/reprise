import AppKit
import SwiftUI
import XCTest
@testable import Reprise

final class MemorySearchFieldTests: XCTestCase {
    @MainActor func testReturnCommitsTextAndSubmitsWithoutSelectingIt() {
        var query = "before commit", focused = true, submissions: [String] = []
        let bridge = MemorySearchField(text: Binding(get: { query }, set: { query = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }), fontSize: 17,
            onSubmit: { submissions.append(query) })
        let coordinator = bridge.makeCoordinator()
        let field = NSTextField(string: "Find the earlier memory")
        let editor = NSTextView(); editor.string = field.stringValue
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submissions, ["Find the earlier memory"])
        XCTAssertFalse(focused)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: editor.string.utf16.count, length: 0))
    }

    @MainActor func testReturnDoesNotSubmitDuringInputMethodComposition() {
        var submitted = false
        let bridge = MemorySearchField(text: .constant(""), isFocused: .constant(true), fontSize: 17, onSubmit: { submitted = true })
        let coordinator = bridge.makeCoordinator()
        let field = NSTextField(string: "input")
        let editor = NSTextView()
        editor.setMarkedText("input", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(submitted)
    }
}
