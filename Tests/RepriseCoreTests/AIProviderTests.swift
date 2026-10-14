import XCTest
import Darwin
@testable import RepriseCore

final class AIProviderTests: XCTestCase {
    private let references = [AICitation(momentID: "fixture-1", label: "M1")]

    private func parse(_ json: String, provider: AIProviderKind = .claude) throws -> AIResponse {
        try AIResponseParser.parse(Data(json.utf8), provider: provider, requestedModel: "",
                                   citations: references, duration: 0.1)
    }

    func testClaudeResponsePreservesEmittedUsageAndCitation() throws {
        let response = try parse(#"{"type":"result","subtype":"success","result":"{\"answer\":\"Recorded text [M1]\",\"citations\":[\"M1\"]}","usage":{"input_tokens":20,"output_tokens":8},"total_cost_usd":0.002,"model":"fixture-model"}"#)
        XCTAssertEqual(response.text, "Recorded text [M1]")
        XCTAssertEqual(response.citations, references)
        XCTAssertEqual(response.usage.inputTokens, 20)
        XCTAssertEqual(response.usage.outputTokens, 8)
        XCTAssertEqual(response.usage.costUSD, 0.002)
        XCTAssertEqual(response.usage.model, "fixture-model")
    }

    func testCodexCompletionMustFollowAgentMessage() throws {
        let output = """
        {"type":"item.completed","item":{"type":"agent_message","text":"{\\"answer\\":\\"Answer [M1]\\",\\"citations\\":[\\"M1\\"]}"}}
        {"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":4}}
        """
        let response = try parse(output, provider: .codex)
        XCTAssertEqual(response.usage.inputTokens, 3)
        XCTAssertNil(response.usage.costUSD)
        XCTAssertEqual(response.usage.model, "auto")
        XCTAssertThrowsError(try parse(output.components(separatedBy: "\n")[0], provider: .codex))
    }

    func testGrokWireResultAndSingleObject() throws {
        let result = #"{"type":"result","subtype":"success","result":"{\"answer\":\"Unknown\",\"citations\":[]}","usage":{"input_tokens":1,"output_tokens":2}}"#
        XCTAssertEqual(try parse(result, provider: .grok).usage.outputTokens, 2)
        let single = #"{"stopReason":"end_turn","text":"{\"answer\":\"Unknown\",\"citations\":[]}" }"#
        XCTAssertEqual(try parse(single, provider: .grok).text, "Unknown")
        let camelCase = #"{"stopReason":"end_turn","structuredOutput":{"answer":"Found [M1]","citations":["M1"]},"modelUsage":{"grok-fixture":{}}}"#
        XCTAssertEqual(try parse(camelCase, provider: .grok).citations, references)
        XCTAssertEqual(try parse(camelCase, provider: .grok).usage.model, "grok-fixture")
    }

    func testGrokPromptEnvelopeAndBoundedCitationSchema() throws {
        let input = try AIEvidenceInput(question: "Question", moments: [Moment(id: "fixture", appName: "Fixture", text: "Evidence")])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: AICommand.grokPrompt(input.prompt)) as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "acp")
        let content = try XCTUnwrap(envelope["content"] as? [[String: String]])
        XCTAssertEqual(content.first?["text"], String(data: input.prompt, encoding: .utf8))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.constrainedSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let items = try XCTUnwrap(properties["citations"]?["items"] as? [String: Any])
        XCTAssertEqual(items["enum"] as? [String], ["M1"])
    }

    func testKernelSandboxUsesCanonicalPathsAndBlocksExternalWritesAndForks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("reprise-sandbox-\(UUID().uuidString)")
        let outside = fm.temporaryDirectory.appendingPathComponent("reprise-denied-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        let fixture = #"my $a=open(my $f,'>',$ARGV[0]); close($f) if $a; my $b=open(my $g,'>',$ARGV[1]); close($g) if $b; my $p=fork(); if (defined($p) && !$p) { exit; } print join(',', $a?1:0, $b?1:0, defined($p)?1:0);"#
        let result = try await AIProcessRunner.run(executable: AIProcessSandbox.executable,
            arguments: ["-p", AIProcessSandbox.profile(root: root, executable: perl), perl.path, "-e", fixture,
                        root.appendingPathComponent("allowed").path, outside.path], input: Data(), timeout: 3)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "1,0,0")
        XCTAssertFalse(fm.fileExists(atPath: outside.path))
    }

    func testUnknownAndInvalidMeasurementsStayUnknown() throws {
        let response = try parse(#"{"type":"result","subtype":"success","structured_output":{"answer":"Unknown","citations":[]},"usage":{"input_tokens":true,"output_tokens":-2},"total_cost_usd":"0.5"}"#)
        XCTAssertNil(response.usage.inputTokens)
        XCTAssertNil(response.usage.outputTokens)
        XCTAssertNil(response.usage.costUSD)
    }

    func testMalformedAndErrorResultsAreRejected() {
        for output in [
            "not json",
            #"{"type":"result","subtype":"success","result":"plain answer"}"#,
            #"{"type":"result","subtype":"error_max_turns","is_error":true}"#,
            #"{"type":"result","subtype":"success","structured_output":{"answer":"","citations":[]}}"#,
            #"{"type":"result","subtype":"success","structured_output":{"answer":"x","citations":[]}}"# + "\nnot-json"
        ] {
            XCTAssertThrowsError(try parse(output))
        }
    }

    func testToolsAndFabricatedCitationsAreRejected() {
        let tool = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#
        XCTAssertThrowsError(try parse(tool)) { XCTAssertEqual($0 as? AIProviderError, .toolAttempt) }
        let wrong = #"{"type":"result","subtype":"success","structured_output":{"answer":"x [M99]","citations":["M99"]}}"#
        XCTAssertThrowsError(try parse(wrong)) { XCTAssertEqual($0 as? AIProviderError, .invalidCitation) }
        let hidden = #"{"type":"result","subtype":"success","structured_output":{"answer":"x [M99]","citations":[]}}"#
        XCTAssertThrowsError(try parse(hidden)) { XCTAssertEqual($0 as? AIProviderError, .invalidCitation) }
    }

    func testEvidenceIsBoundedAndDoesNotIncludeMetadataOrPaths() throws {
        let moments = (0..<100).map {
            Moment(id: "fixture-\($0)", appName: "DO-NOT-SEND-APP", windowTitle: "DO-NOT-SEND-TITLE",
                   text: String(repeating: "한", count: 5000), imagePath: "/DO-NOT-SEND-PATH")
        }
        let input = try AIEvidenceInput(question: "Question", moments: moments)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: input.prompt) as? [String: Any])
        let rows = try XCTUnwrap(json["evidence"] as? [[String: String]])
        XCTAssertEqual(rows.count, 24, "A long recent frame must not starve older candidates of the evidence budget")
        XCTAssertEqual(input.citations.last?.momentID, "fixture-23")
        XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + ($1["text"]?.utf8.count ?? 0) }, 32 * 1024)
        XCTAssertFalse(String(decoding: input.prompt, as: UTF8.self).contains("DO-NOT-SEND"))
        XCTAssertEqual(input.citations.count, rows.count)
        XCTAssertThrowsError(try AIEvidenceInput(question: " ", moments: []))
        XCTAssertThrowsError(try AIEvidenceInput(question: String(repeating: "x", count: 8193), moments: []))
    }

    func testToolFreeClaudeArgumentsAndAutomaticModel() {
        let args = AICommand.arguments(configuration: AIProviderConfiguration())
        XCTAssertEqual(args[try! XCTUnwrap(args.firstIndex(of: "--tools")) + 1], "")
        XCTAssertTrue(args.contains("--safe-mode"))
        XCTAssertTrue(args.contains("--restricted"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(AICommand.validModel("--model=other"))
        XCTAssertFalse(AICommand.validModel("name\nflag"))
        let configured = AICommand.arguments(configuration: AIProviderConfiguration(model: "opus"))
        XCTAssertEqual(configured.suffix(2), ["--model", "opus"])
        XCTAssertFalse(AICommand.supportsAnswering(provider: .codex, help: "--json"))
        XCTAssertFalse(AICommand.supportsAnswering(provider: .grok, help: "--tools"))
    }

    func testBoundedProcessTimeout() async {
        do {
            _ = try await AIProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                              arguments: ["5"], input: Data(), timeout: 0.08)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .timedOut)
        }
    }

    func testBoundedProcessCancellation() async {
        let task = Task {
            try await AIProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                         arguments: ["5"], input: Data(), timeout: 10)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || error as? AIProviderError == .cancelled)
        }
    }

    func testBoundedProcessRejectsOutputFlood() async {
        do {
            _ = try await AIProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                              arguments: ["fixture"], input: Data(), timeout: 2, outputLimit: 1024)
            XCTFail("Expected bounded output failure")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .outputLimit)
        }
    }

    func testTimeoutKillsOwnedDescendant() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // Synthetic fixture only. Process receives code and its own file path as separate arguments.
        let code = #"$SIG{TERM}='IGNORE'; my $pid=fork(); if (!$pid) { sleep 20; exit; } open(my $fh,'>',$ARGV[0]) or die; print $fh $pid; close($fh); sleep 20;"#
        do {
            _ = try await AIProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                                              arguments: ["-e", code, pidFile.path], input: Data(), timeout: 0.15)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .timedOut)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Timed-out descendant must be gone")
    }

    func testInstalledStatusIsModelFreeAndQuotaUnknown() async throws {
        try requireNativeProviders()
        let client = AIClient()
        for provider in AIProviderKind.allCases {
            let status = await client.status(configuration: AIProviderConfiguration(provider: provider))
            // Local models depend on this Mac's settings and downloads, not on an installed CLI.
            if !provider.runsOnThisMac {
                XCTAssertTrue(status.isInstalled)
                XCTAssertTrue(status.canAnswer, "\(provider): \(status.message)")
            }
            XCTAssertNil(status.quotaRemaining)
            XCTAssertFalse(status.authenticationVerified)
        }
    }

    func testCodexToolCatalogIsAcceptedByInstalledCLI() async throws {
        try requireNativeProviders()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-catalog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("models.json")
        try CodexAnswerCatalog.data().write(to: catalog)
        let executable = try XCTUnwrap(AICommand.executable(AIProviderConfiguration(provider: .codex)))
        let profile = AICommand.arguments(configuration: AIProviderConfiguration(provider: .codex))
        var overrides: [String] = []
        for index in profile.indices where profile[index] == "-c" { overrides += ["-c", profile[index + 1]] }
        let result = try await AIProcessRunner.run(executable: executable,
            arguments: ["debug", "models"] + overrides + ["-c", "model_catalog_json=\(AICommand.tomlString(catalog.path))"],
            input: Data(), timeout: 8, environment: ["CODEX_HOME": root.path])
        XCTAssertEqual(result.exitCode, 0)
        let parsed = try JSONSerialization.jsonObject(with: result.stdout)
        let models = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        XCTAssertFalse(models.isEmpty)
        for model in models {
            XCTAssertEqual(model["shell_type"] as? String, "disabled")
            XCTAssertTrue(model["apply_patch_tool_type"] is NSNull)
            XCTAssertEqual(model["experimental_supported_tools"] as? [String], [])
            XCTAssertEqual(model["multi_agent_version"] as? String, "disabled")
        }
        XCTAssertThrowsError(try CodexAnswerCatalog.model(requested: "unknown-fixture-model"))
    }

    func testGrokIsolatedHomeHasNoCustomizations() async throws {
        try requireNativeProviders()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-grok-test-\(UUID().uuidString)")
        let home = root.appendingPathComponent("grok")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(AICommand.grokConfig.utf8).write(to: home.appendingPathComponent("config.toml"))
        let executable = try XCTUnwrap(AICommand.executable(AIProviderConfiguration(provider: .grok)))
        let result = try await AIProcessRunner.run(executable: executable, arguments: ["inspect", "--json"],
            input: Data(), timeout: 8, environment: AICommand.grokEnvironment(root: root, home: home))
        XCTAssertEqual(result.exitCode, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        for field in ["mcpServers", "hooks", "plugins", "skills", "projectInstructions"] {
            XCTAssertEqual((object[field] as? [Any])?.count, 0, field)
        }
        let help = try await AIProcessRunner.run(executable: executable,
            arguments: AICommand.arguments(configuration: AIProviderConfiguration(provider: .grok)) + ["--help"],
            input: Data(), timeout: 8, environment: AICommand.grokEnvironment(root: root, home: home))
        XCTAssertEqual(help.exitCode, 0)
    }

    private func requireNativeProviders() throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_NATIVE_PROVIDERS"] == "1" else {
            throw XCTSkip("Set REPRISE_TEST_NATIVE_PROVIDERS=1 to check installed CLI metadata contracts without inference.")
        }
    }

    func testAntigravityCursorAndOpenCodeStreams() throws {
        let answer = #"{\"answer\":\"Found [M1]\",\"citations\":[\"M1\"]}"#
        let gemini = """
        {"event":"init"}
        {"event":"step_update","step_update":{"step_type":"agent_response"}}
        {"event":"result","result":{"status":"SUCCESS","response":"\(answer)","usage":{"input_tokens":13800,"output_tokens":12},"denied_actions":[]}}
        """
        XCTAssertEqual(try parse(gemini, provider: .gemini).citations, references)
        XCTAssertEqual(try parse(gemini, provider: .gemini).usage.inputTokens, 13800)
        XCTAssertThrowsError(try parse(gemini.replacingOccurrences(of: "agent_response", with: "tool"), provider: .gemini)) {
            XCTAssertEqual($0 as? AIProviderError, .toolAttempt)
        }
        XCTAssertThrowsError(try parse(gemini.replacingOccurrences(of: #""denied_actions":[]"#, with: #""denied_actions":["run_command"]"#), provider: .gemini)) {
            XCTAssertEqual($0 as? AIProviderError, .toolAttempt)
        }
        XCTAssertThrowsError(try parse(#"{"event":"result","result":{"status":"ERROR","error":"Please sign in again"}}"#, provider: .gemini)) {
            XCTAssertEqual($0 as? AIProviderError, .authenticationRequired)
        }
        XCTAssertEqual(AICommand.geminiSchema(#"{"properties":{"kind":{"type":["string","null"],"enum":["screen",null]},"none":{"enum":[null]}}}"#),
                       #"{"properties":{"kind":{"anyOf":[{"enum":["screen"],"type":"string"},{"type":"null"}]},"none":{"type":"null"}}}"#)
        // The structured answer comes back through Antigravity's finish step and the result.
        let finished = """
        {"event":"step_update","step_update":{"step_type":"tool","tool_name":"finish","tool_info":{"name":"finish","parameters":{"answer":"Found [M1]","citations":["M1"]}}}}
        {"event":"result","result":{"status":"SUCCESS","response":"```json\\n{}\\n```","structured_output":{"answer":"Found [M1]","citations":["M1"]},"usage":{"input_tokens":1,"output_tokens":2}}}
        """
        XCTAssertEqual(try parse(finished, provider: .gemini).text, "Found [M1]")
        XCTAssertThrowsError(try parse(finished.replacingOccurrences(of: #""tool_name":"finish""#, with: #""tool_name":"run_command""#), provider: .gemini)) {
            XCTAssertEqual($0 as? AIProviderError, .toolAttempt)
        }

        // Cursor's result text joins every assistant message, so the last message is the answer.
        let cursor = """
        {"type":"system","subtype":"init","model":"Auto"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Checking the evidence."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(answer)"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Checking the evidence.\(answer)"}
        """
        XCTAssertEqual(try parse(cursor, provider: .cursor).text, "Found [M1]")
        let cursorTool = cursor.replacingOccurrences(of: #"{"type":"system","subtype":"init","model":"Auto"}"#,
                                                     with: #"{"type":"tool_call","subtype":"started","tool_call":{}}"#)
        XCTAssertThrowsError(try parse(cursorTool, provider: .cursor)) { XCTAssertEqual($0 as? AIProviderError, .toolAttempt) }

        // OpenCode streams text parts and ends the step with a reason.
        let opencode = """
        {"type":"step_start","part":{"type":"step-start"}}
        {"type":"text","part":{"type":"text","text":"Here it is: {\\"answer\\":\\"Found [M1]\\","}}
        {"type":"text","part":{"type":"text","text":"\\"citations\\":[\\"M1\\"]}"}}
        {"type":"step_finish","part":{"type":"step-finish","reason":"stop","tokens":{"input":35000,"output":20}}}
        """
        let parsed = try parse(opencode, provider: .opencode)
        XCTAssertEqual(parsed.text, "Found [M1]")
        XCTAssertEqual(parsed.usage.inputTokens, 35000)
        XCTAssertThrowsError(try parse(opencode.replacingOccurrences(of: #""reason":"stop""#, with: #""reason":"tool-calls""#), provider: .opencode)) {
            XCTAssertEqual($0 as? AIProviderError, .toolAttempt)
        }
    }

    func testGrokStructuredPlanAndPartialUsage() throws {
        let data = Data(#"{"stopReason":"end_turn","structured_output":{"terms":["forecast"],"since":null,"until":null,"kind":null},"usage":{"input_tokens":20},"usage_is_incomplete":true,"total_cost_usd":0.5}"#.utf8)
        let parsed = try AIResponseParser.structured(data, provider: .grok, requestedModel: "", duration: 1)
        XCTAssertEqual(parsed.payload["terms"] as? [String], ["forecast"])
        XCTAssertNil(parsed.usage.inputTokens)
        XCTAssertNil(parsed.usage.costUSD)
    }
}
