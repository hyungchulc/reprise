import XCTest
import MCP
import RepriseCore
@testable import RepriseMCPKit

final class MCPTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDefaultDenyDoesNotCreateLibraryAndLiveRevocation() async throws {
        let root = try fixture()
        let service = MemoryTools(root: root)
        let denied = await service.call(name: "reprise_library_status", arguments: [:])
        XCTAssertEqual(denied.isError, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path))
        let store = try MomentStore(root: root)
        try await store.insert(Moment(id: "one", appName: "Fixture", text: "unique fixture"))
        try MCPAccess(enabled: true).save(root: root)
        let enabled = MemoryTools(root: root)
        let found = await enabled.call(name: "reprise_search", arguments: ["text": "unique"])
        XCTAssertEqual(found.structuredContent?.objectValue?["memories"]?.arrayValue?.count, 1)
        try MCPAccess().save(root: root)
        let revoked = await enabled.call(name: "reprise_get_memory", arguments: ["id": "one"])
        XCTAssertEqual(revoked.isError, true)
    }

    func testTranscriptSearchPaginationAndLiveDatabaseChanges() async throws {
        let root = try fixture(), store = try MomentStore(root: root)
        try MCPAccess(enabled: true).save(root: root)
        let service = MemoryTools(root: root)
        for n in 0..<3 {
            try await store.insert(Moment(id: "audio\(n)", timestamp: Date(timeIntervalSince1970: Double(n)), appName: "Meeting",
                text: "meeting transcript \(n)", videoPath: "audio/test.m4a", kind: "meeting",
                transcriptSegments: [.init(start: 0, end: 1, text: "meeting transcript")]))
        }
        let first = await service.call(name: "reprise_search", arguments: ["kind": "meeting", "limit": 2])
        XCTAssertEqual(first.structuredContent?.objectValue?["next_offset"], .int(2))
        let page = await service.call(name: "reprise_search", arguments: ["text": "transcript", "kind": "meeting", "offset": 2, "limit": 2])
        XCTAssertEqual(page.structuredContent?.objectValue?["memories"]?.arrayValue?.count, 1)
        let detail = await service.call(name: "reprise_get_memory", arguments: ["id": "audio0", "text_limit": 7])
        XCTAssertEqual(detail.structuredContent?.objectValue?["text"], .string("meeting"))
        XCTAssertEqual(detail.structuredContent?.objectValue?["next_text_offset"], .int(7))
        XCTAssertNil(detail.structuredContent?.objectValue?["videoPath"])
        try await store.updateTranscript(id: "audio0", text: "updated text", segments: [], note: nil)
        let updated = await service.call(name: "reprise_get_memory", arguments: ["id": "audio0"])
        XCTAssertEqual(updated.structuredContent?.objectValue?["text"], .string("updated text"))
    }

    func testFiltersInvalidArgumentsAndOverviewCoverage() async throws {
        let root = try fixture(), store = try MomentStore(root: root)
        try MCPAccess(enabled: true).save(root: root)
        for n in 0..<10 {
            try await store.insert(Moment(timestamp: Date(timeIntervalSince1970: Double(n * 3600)), appName: "Fixture", text: "example"))
        }
        let service = MemoryTools(root: root)
        let result = await service.call(name: "reprise_activity_overview", arguments: ["limit": 2])
        XCTAssertEqual(result.structuredContent?.objectValue?["coverage"]?.objectValue?["total_records"], .int(10))
        XCTAssertEqual(result.structuredContent?.objectValue?["memories"]?.arrayValue?.count, 2)
        for args: [String: Value] in [["limit": 1000], ["limit": "20"], ["path": "/etc/passwd"], ["kind": "other"],
            ["since": "yesterday"], ["since": "2026-02-01T00:00:00Z", "until": "2026-01-01T00:00:00Z"]] {
            let invalid = await service.call(name: "reprise_search", arguments: args)
            XCTAssertEqual(invalid.isError, true)
        }
        let excluded = await service.call(name: "reprise_search", arguments: ["app": "Missing"])
        XCTAssertEqual(excluded.structuredContent?.objectValue?["memories"]?.arrayValue?.count, 0)
    }

    func testReadOnlyAndMediaPathGuards() async throws {
        let root = try fixture(), writable = try MomentStore(root: root)
        try await writable.insert(Moment(id: "screen", appName: "Fixture", imagePath: "screen.jpg"))
        let readOnly = try MomentStore(root: root, readOnly: true)
        do { try await readOnly.insert(Moment(appName: "Forbidden")); XCTFail("Read-only connection allowed a write") } catch {}
        for path in ["../secret", "/etc/passwd", "library.sqlite"] {
            do { _ = try await readOnly.readMedia(path); XCTFail("Unsafe path read") } catch {}
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("screen.jpg"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        do { _ = try await readOnly.readMedia("screen.jpg"); XCTFail("Followed media symlink") } catch {}
        try MCPAccess(enabled: true, allowImages: false).save(root: root)
        let service = MemoryTools(root: root)
        let image = await service.call(name: "reprise_get_screenshot", arguments: ["id": "screen"])
        XCTAssertEqual(image.isError, true)
        try MCPAccess(enabled: true, allowImages: true).save(root: root)
        let unsafe = await service.call(name: "reprise_get_screenshot", arguments: ["id": "screen"])
        XCTAssertEqual(unsafe.isError, true)
    }

    func testClientJSONMergeRemoveConflictAndMalformedPreservation() async throws {
        let home = try fixture(), helper = URL(fileURLWithPath: "/usr/bin/true")
        let installer = MCPClientInstaller(helper: helper, vault: home, home: home)
        for client in MCPClientKind.allCases where client != .codex {
            let url = client.configurationURL(home: home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data(#"{"preference":42,"mcpServers":{"other":{"command":"other"}}}"#.utf8)
            try original.write(to: url)
            try await installer.setInstalled(true, for: client)
            let state = await installer.status(client)
            XCTAssertEqual(state, .installed)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(json["preference"] as? Int, 42)
            XCTAssertNotNil((json["mcpServers"] as? [String: Any])?["other"])
            try await installer.setInstalled(false, for: client)
            let removed = await installer.status(client)
            XCTAssertEqual(removed, .absent)
            let conflict = Data(#"{"mcpServers":{"reprise":{"command":"another"}}}"#.utf8)
            try conflict.write(to: url)
            do { try await installer.setInstalled(true, for: client); XCTFail("Replaced unrelated entry") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), conflict)
            let malformed = Data("{broken".utf8)
            try malformed.write(to: url)
            do { try await installer.setInstalled(true, for: client); XCTFail("Overwrote malformed configuration") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), malformed)
        }
    }

    func testNativeCodexConfigurationInTemporaryHome() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPRISE_TEST_CODEX"] else {
            throw XCTSkip("Set REPRISE_TEST_CODEX to explicitly test installed CLI metadata commands in a temporary home.")
        }
        let home = try fixture()
        let installer = MCPClientInstaller(helper: URL(fileURLWithPath: "/usr/bin/true"), vault: home, home: home, codexExecutable: URL(fileURLWithPath: path))
        let before = await installer.status(.codex)
        XCTAssertEqual(before, .absent)
        try await installer.setInstalled(true, for: .codex)
        let installed = await installer.status(.codex)
        XCTAssertEqual(installed, .installed)
        try await installer.setInstalled(false, for: .codex)
        let removed = await installer.status(.codex)
        XCTAssertEqual(removed, .absent)
    }
}
