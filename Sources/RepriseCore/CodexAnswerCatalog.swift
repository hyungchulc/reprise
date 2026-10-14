import Foundation

/// A per-invocation copy of noncredential model metadata removes catalog-advertised tools.
enum CodexAnswerCatalog {
  static var isAvailable: Bool { (try? data()) != nil }

  static func model(requested: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data()) as! [String: Any]
    let models = object["models"] as! [[String: Any]]
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

  /// Reasoning levels the model lists, lowest first; a blank model means the catalog's default.
  static func reasoningLevels(model: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
    let url = home.appendingPathComponent(".codex/models_cache.json")
    guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 && $0 <= 4 * 1024 * 1024 }) == true,
      let cache = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let models = cache["models"] as? [[String: Any]],
      let slug = model.isEmpty ? try? self.model(requested: "") : model,
      let entry = models.first(where: { $0["slug"] as? String == slug })
    else { return [] }
    let levels = (entry["supported_reasoning_levels"] as? [Any] ?? []).compactMap { level -> String? in
      let name = (level as? [String: Any])?["effort"] as? String ?? level as? String
      return name.flatMap { $0.count <= 16 && $0.allSatisfy { $0.isASCII && $0.isLetter } ? $0 : nil }
    }
    return levels
  }

  static func data(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Data {
    let url = home.appendingPathComponent(".codex/models_cache.json")
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size > 0, size <= 4 * 1024 * 1024,
      let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let models = cache["models"] as? [[String: Any]], !models.isEmpty
    else {
      throw AIProviderError.unsupportedIsolation
    }
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
