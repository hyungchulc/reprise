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
            guard let executable = AICommand.executable(configuration),
                  let output = try? await AIProcessRunner.run(executable: executable, arguments: ["models"], input: Data(), timeout: 8, outputLimit: 32 * 1024), output.exitCode == 0 else { return [] }
            return Self.grokModels(String(decoding: output.stdout, as: UTF8.self))
        }
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
}
