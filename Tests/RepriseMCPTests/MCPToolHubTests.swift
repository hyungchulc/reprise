import XCTest
@testable import RepriseMCPKit

/// The meeting assistant's MCP client, against Reprise's own MCP helper as a stand-in server.
final class MCPToolHubTests: XCTestCase {
    func testCommandLinesSplitLikeAShell() throws {
        XCTAssertEqual(try MCPToolHub.commandWords(#"npx -y "@scope/server name" --root '/tmp/a b' plain\ word"#),
                       ["npx", "-y", "@scope/server name", "--root", "/tmp/a b", "plain word"])
        XCTAssertEqual(try MCPToolHub.commandWords("  uvx   tool  "), ["uvx", "tool"])
        XCTAssertThrowsError(try MCPToolHub.commandWords(#"npx "open"#))
        XCTAssertNotNil(MCPToolHub.locate("sh", in: MCPToolHub.searchPath()))
        XCTAssertNil(MCPToolHub.locate("reprise-no-such-program", in: MCPToolHub.searchPath()))
    }

    func testToolsStartOnOnlyWhenReadOnlyOrChosen() {
        let reader = MCPToolInfo(name: "read", description: "", inputSchema: "{}", readOnly: true)
        let writer = MCPToolInfo(name: "write", description: "", inputSchema: "{}", readOnly: false)
        var server = MCPServerSetting(name: "x", command: "x")
        XCTAssertTrue(server.allows(reader))
        XCTAssertFalse(server.allows(writer))
        server.toolChoices = ["write": true, "read": false]
        XCTAssertTrue(server.allows(writer))
        XCTAssertFalse(server.allows(reader))
    }

    /// Starts the helper with an empty vault, lists its tools, calls one and stops it.
    func testConnectsListsCallsAndStopsACommandServer() async throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("RepriseMCP")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("Build the RepriseMCP helper first.") }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-hub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let hub = MCPToolHub()
        let server = MCPServerSetting(name: "Helper", command: "'\(helper.path)' --vault '\(vault.path)'")
        let tools = try await hub.connect(server, secrets: MCPServerSecrets())
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.allSatisfy { $0.inputSchema.hasPrefix("{") })
        let status = try XCTUnwrap(tools.first { $0.name == "reprise_library_status" } ?? tools.first)
        let answer = try await hub.call(server.id, tool: status.name, arguments: "{}")
        XCTAssertFalse(answer.isEmpty)
        await hub.disconnectAll()
        do {
            _ = try await hub.call(server.id, tool: status.name, arguments: "{}")
            XCTFail("A disconnected server answered")
        } catch {}
        let missing = MCPServerSetting(name: "Missing", command: "reprise-no-such-program --flag")
        do {
            _ = try await hub.connect(missing, secrets: MCPServerSecrets())
            XCTFail("A missing program connected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("was not found"))
        }
    }
}
