import Foundation

public struct AIModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public extension AIClient {
    /// Catalog metadata only. This never sends a prompt or reads credential contents.
    func models(configuration: AIProviderConfiguration) async -> [AIModelOption] {
        switch configuration.provider {
        case .codex:
            guard let data = try? CodexAnswerCatalog.data(),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]] else { return [] }
            return models.filter { $0["visibility"] as? String == "list" }
                .sorted { ($0["priority"] as? Int ?? 999) < ($1["priority"] as? Int ?? 999) }
                .compactMap { value in
                    guard let id = value["slug"] as? String, AICommand.validModel(id) else { return nil }
                    return AIModelOption(id: id, name: value["display_name"] as? String ?? id)
                }
        case .claude:
            // The installed CLI documents these moving aliases, not a fixed generation.
            guard let executable = AICommand.executable(configuration),
                  let help = try? await AIProcessRunner.run(executable: executable, arguments: ["--help"], input: Data(), timeout: 8, outputLimit: 128 * 1024) else { return [] }
            let text = String(decoding: help.stdout, as: UTF8.self)
            return ["fable", "opus", "sonnet"].filter { text.contains("'\($0)'") }
                .map { AIModelOption(id: $0, name: "\($0.capitalized) (latest)") }
        case .grok:
            guard let output = await listing(configuration, ["models"]) else { return [] }
            return Self.grokModels(output)
        case .gemini:
            guard let output = await listing(configuration, ["models"], timeout: 20) else { return [] }
            return Self.geminiModels(output)
        case .cursor:
            guard let output = await listing(configuration, ["--list-models"], timeout: 20) else { return [] }
            return Self.cursorModels(output)
        case .opencode:
            guard let executable = AICommand.executable(configuration) else { return [] }
            // A private config folder lists OpenCode's own catalog without the person's providers.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-models-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let environment = ["XDG_CONFIG_HOME": root.appendingPathComponent("config").path, "XDG_DATA_HOME": root.appendingPathComponent("data").path,
                               "XDG_STATE_HOME": root.appendingPathComponent("state").path, "XDG_CACHE_HOME": AICommand.openCodeCache.deletingLastPathComponent().path]
            // Without a recent catalog OpenCode lists the old one it was built with, so fetch it first.
            let catalog = AICommand.openCodeCache.appendingPathComponent("models.json")
            let updated = (try? catalog.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let refresh = Date().timeIntervalSince(updated) > 86_400 ? ["--refresh"] : []
            guard let output = try? await AIProcessRunner.run(executable: executable, arguments: ["models", "opencode", "--pure"] + refresh, input: Data(),
                      timeout: 30, outputLimit: 64 * 1024, environment: environment), output.exitCode == 0 else { return [] }
            return Self.openCodeModels(String(decoding: output.stdout, as: UTF8.self))
        case .ollama:
            return await Ollama.models().map { AIModelOption(id: $0, name: $0) }
        case .apple:
            return []
        }
    }

    private func listing(_ configuration: AIProviderConfiguration, _ arguments: [String], timeout: Double = 8) async -> String? {
        guard let executable = AICommand.executable(configuration),
              let output = try? await AIProcessRunner.run(executable: executable, arguments: arguments, input: Data(), timeout: timeout, outputLimit: 64 * 1024),
              output.exitCode == 0 else { return nil }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    internal static func grokModels(_ text: String) -> [AIModelOption] {
        var found = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, ["-", "*"].contains(String(parts[0])) else { return nil }
            let id = String(parts[1])
            guard id.hasPrefix("grok-"), AICommand.validModel(id), found.insert(id).inserted else { return nil }
            return AIModelOption(id: id, name: id)
        }
    }

    /// `agy models` prints one `id<TAB>Display name` row per model.
    internal static func geminiModels(_ text: String) -> [AIModelOption] {
        var found = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, AICommand.validModel(id), found.insert(id).inserted else { return nil }
            return AIModelOption(id: id, name: parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// `cursor-agent --list-models` prints `id - Display name` rows under a heading.
    internal static func cursorModels(_ text: String) -> [AIModelOption] {
        var found = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            guard let range = line.range(of: " - ") else { return nil }
            let id = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespaces).filter { !$0.unicodeScalars.allSatisfy(\.properties.isDefaultIgnorableCodePoint) }
            guard !id.isEmpty, !id.contains(" "), AICommand.validModel(id), found.insert(id).inserted else { return nil }
            return AIModelOption(id: id, name: name)
        }
    }

    /// Free OpenCode Zen models. Providers of most free models may keep prompts to improve their
    /// models; those that keep nothing come first and are marked.
    internal static func openCodeModels(_ text: String) -> [AIModelOption] {
        let private_ = ["space-bunny", "longcat", "step-"]
        let ids = Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("opencode/") && ($0.hasSuffix("-free") || $0 == "opencode/big-pickle") && AICommand.validModel($0) })
        func keepsNothing(_ id: String) -> Bool { private_.contains { id.dropFirst("opencode/".count).hasPrefix($0) } }
        return ids.sorted { (keepsNothing($0) ? 0 : 1, $0) < (keepsNothing($1) ? 0 : 1, $1) }.map { id in
            let base = id.dropFirst("opencode/".count).replacingOccurrences(of: "-free", with: "")
                .split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return AIModelOption(id: id, name: base + (keepsNothing(id) ? " (free, not kept)" : " (free, may be used for training)"))
        }
    }
}
