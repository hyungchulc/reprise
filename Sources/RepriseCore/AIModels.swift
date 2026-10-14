import Foundation

public struct AIModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// The model the CLI uses when Reprise names none, when its list marks one.
    public var isDefault = false
}

/// Models that differ only in thinking level or speed, as Gemini and Cursor list them
/// (`claude-opus-5-5-high-fast`), grouped so the level can be chosen on its own.
public struct AIModelFamily: Identifiable, Equatable, Sendable {
    public struct Level: Equatable, Sendable {
        /// Empty when the model names no level.
        public let level: String
        public let model: String
    }
    public let id: String
    public let name: String
    public let levels: [Level]

    public static let levelOrder = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// The family a model identifier belongs to and the level it names.
    public static func split(_ id: String) -> (family: String, level: String) {
        var core = id, fast = ""
        if core.hasSuffix("-fast") { core.removeLast(5); fast = "-fast" }
        for level in levelOrder where core.hasSuffix("-" + level) && core.count > level.count + 1 {
            return (String(core.dropLast(level.count + 1)) + fast, level)
        }
        return (id, "")
    }

    public static func families(_ options: [AIModelOption]) -> [AIModelFamily] {
        var order: [String] = [], members: [String: [(option: AIModelOption, level: String)]] = [:]
        for option in options {
            let (family, level) = split(option.id)
            if members[family] == nil { order.append(family) }
            members[family, default: []].append((option, level))
        }
        return order.map { family in
            let items = members[family] ?? []
            let levels = items.map { Level(level: $0.level, model: $0.option.id) }
                .sorted { (levelOrder.firstIndex(of: $0.level) ?? -1) < (levelOrder.firstIndex(of: $1.level) ?? -1) }
            let named = items.first { $0.level.isEmpty || $0.level == "medium" } ?? items[0]
            return AIModelFamily(id: family, name: displayName(named.option.name, level: named.level), levels: levels)
        }
    }

    /// "Gemini 3.8 Flash (High)" or "Claude Opus 5.5 1M Extra High Fast" without the level words.
    static func displayName(_ name: String, level: String) -> String {
        guard !level.isEmpty else { return name }
        var result = name
        for word in level == "xhigh" ? ["Extra High", "XHigh"] : [label(level)] {
            for pattern in [" (\(word))", " \(word)"] {
                if let range = result.range(of: pattern, options: .backwards) {
                    result.removeSubrange(range)
                    return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                }
            }
        }
        return result
    }

    public func model(for level: String) -> String? { levels.first { $0.level == level }?.model }

    /// The level to use when switching to this family: the same one if it has it, else its
    /// unnamed or medium model, else its first.
    public func model(keeping level: String) -> String {
        model(for: level) ?? model(for: "") ?? model(for: "medium") ?? levels[0].model
    }

    /// The listed model that is the same model at the other speed. Providers that name speed in
    /// the model put `-fast` at the end, sometimes after a build name (`grok-4.7` and
    /// `grok-4.7-build-fast`), so the closest listed name wins.
    public static func speedCounterpart(of id: String, fast: Bool, in ids: [String]) -> String? {
        if fast {
            guard !id.hasSuffix("-fast") else { return nil }
            if ids.contains(id + "-fast") { return id + "-fast" }
            return ids.filter { $0.hasSuffix("-fast") && $0.dropLast(5).hasPrefix(id + "-") }.min { $0.count < $1.count }
        }
        guard id.hasSuffix("-fast") else { return nil }
        let base = String(id.dropLast(5))
        if ids.contains(base) { return base }
        return ids.filter { !$0.hasSuffix("-fast") && base.hasPrefix($0 + "-") }.max { $0.count < $1.count }
    }

    public static func label(_ level: String) -> String {
        switch level {
        case "": "Default"
        case "xhigh": "Extra High"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    /// Antigravity's own default model thinks for a minute or more on small requests, so the
    /// automatic Gemini choice is the light-thinking Flash model from its current list.
    public static func geminiDefault(_ options: [AIModelOption]) -> String? {
        let ids = options.map(\.id)
        return ids.first { $0.hasPrefix("gemini-") && $0.contains("flash") && $0.hasSuffix("-low") }
            ?? ids.first { $0.hasPrefix("gemini-") && $0.hasSuffix("-low") }
    }
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
        case .openAIAPI, .anthropicAPI, .geminiAPI:
            return await ProviderAPI.models(configuration.provider)
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
            // `*` marks the model the CLI uses by default.
            return AIModelOption(id: id, name: id, isDefault: parts[0] == "*")
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
