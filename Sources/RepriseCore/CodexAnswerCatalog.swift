import Foundation

/// A per-invocation copy of noncredential model metadata removes catalog-advertised tools.
enum CodexAnswerCatalog {
  static var isAvailable: Bool { (try? data()) != nil }

  static func model(requested: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
    guard let models = models(home: home) else { throw AIProviderError.unsupportedIsolation }
    if !requested.isEmpty {
      guard models.contains(where: { $0["slug"] as? String == requested }) else {
        throw AIProviderError.invalidInput
      }
      return requested
    }
    let visible = models.filter { $0["visibility"] as? String == "list" }
    guard
      let preferred = visible.min(by: {
        ($0["priority"] as? Int ?? Int.max) < ($1["priority"] as? Int ?? Int.max)
      }),
      let slug = preferred["slug"] as? String, AICommand.validModel(slug)
    else { throw AIProviderError.unsupportedIsolation }
    return slug
  }

  /// The listed model the catalog calls fast, for quick lookups; nil when none says so.
  static func fastModel(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
    models(home: home)?.filter { $0["visibility"] as? String == "list" }
      .sorted { ($0["priority"] as? Int ?? Int.max) < ($1["priority"] as? Int ?? Int.max) }
      .first { ($0["description"] as? String)?.lowercased().hasPrefix("fast") == true }
      .flatMap { $0["slug"] as? String }.flatMap { AICommand.validModel($0) ? $0 : nil }
  }

  /// The models Codex itself works from: the catalog file its config names in `model_catalog_json`,
  /// else the cache Codex downloads. Only that one path is read from the config. Models a proxy
  /// serves under a provider prefix, such as "cursor/...", are left out: Reprise runs Codex against
  /// OpenAI directly.
  static func models(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [[String: Any]]? {
    let codex = home.appendingPathComponent(".codex", isDirectory: true)
    for url in [configuredCatalog(codex: codex, home: home), codex.appendingPathComponent("models_cache.json")].compactMap({ $0 }) {
      guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 && $0 <= 4 * 1024 * 1024 }) == true,
        let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        let models = (object["models"] as? [[String: Any]])?.filter({ ($0["slug"] as? String).map { !$0.contains("/") } ?? false }),
        !models.isEmpty
      else { continue }
      return models
    }
    return nil
  }

  /// The top-level `model_catalog_json` path in Codex's config, which comes before its first table.
  static func configuredCatalog(codex: URL, home: URL) -> URL? {
    let url = codex.appendingPathComponent("config.toml")
    guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 && $0 <= 1024 * 1024 }) == true,
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { return nil }
      let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2, parts[0] == "model_catalog_json", let quote = parts[1].first, quote == "\"" || quote == "'" else { continue }
      let rest = parts[1].dropFirst()
      guard let close = rest.firstIndex(of: quote) else { return nil }
      let path = String(rest[..<close])
      // Escapes in a basic string are left unread rather than guessed at.
      guard !path.isEmpty, quote == "'" || !path.contains("\\") else { return nil }
      if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
      return path.hasPrefix("/") ? URL(fileURLWithPath: path) : codex.appendingPathComponent(path)
    }
    return nil
  }

  /// The catalog entry for a model; a blank model means the catalog's default.
  static func entry(model: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any]? {
    guard let models = models(home: home), let slug = model.isEmpty ? try? self.model(requested: "", home: home) : model else { return nil }
    return models.first(where: { $0["slug"] as? String == slug })
  }

  /// The Fast service tier when the model offers one, with the catalog's own description of its cost.
  static func fastTier(model: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (id: String, note: String)? {
    let tiers = entry(model: model, home: home)?["service_tiers"] as? [[String: Any]] ?? []
    guard let tier = tiers.first(where: { ($0["name"] as? String)?.lowercased() == "fast" || $0["id"] as? String == "priority" }),
      let id = tier["id"] as? String, id.count <= 32, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_" || $0 == "-") })
    else { return nil }
    return (id, String((tier["description"] as? String ?? "").prefix(120)))
  }

  static func contextWindow(model: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int? {
    (entry(model: model, home: home)?["context_window"] as? Int).flatMap { $0 > 0 ? $0 : nil }
  }

  /// Reasoning levels the model lists, lowest first; a blank model means the catalog's default.
  static func reasoningLevels(model: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
    guard let entry = entry(model: model, home: home) else { return [] }
    let levels = (entry["supported_reasoning_levels"] as? [Any] ?? []).compactMap { level -> String? in
      let name = (level as? [String: Any])?["effort"] as? String ?? level as? String
      return name.flatMap { $0.count <= 16 && $0.allSatisfy { $0.isASCII && $0.isLetter } ? $0 : nil }
    }
    return levels
  }

  static func data(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Data {
    guard let models = models(home: home) else { throw AIProviderError.unsupportedIsolation }
    let isolated = models.map { model -> [String: Any] in
      var model = model
      model["shell_type"] = "disabled"
      model["apply_patch_tool_type"] = NSNull()
      model["experimental_supported_tools"] = []
      model["supports_search_tool"] = false
      model["tool_mode"] = "direct"
      model["multi_agent_version"] = "disabled"
      return model
    }
    // Account identity, ETag and other cache envelope fields are never copied.
    return try JSONSerialization.data(withJSONObject: ["models": isolated], options: [.sortedKeys])
  }
}
