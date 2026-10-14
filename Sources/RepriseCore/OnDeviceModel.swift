import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model. Prompts and answers stay on this Mac; the model has no
/// tools, and its small context window gets a smaller share of evidence (see `AIContextBudget`).
enum OnDeviceModel {
    struct Readiness: Sendable {
        let canAnswer: Bool
        let installed: Bool
        let message: String
    }

    static func readiness() -> Readiness {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return Readiness(canAnswer: true, installed: true, message: "Ready on this Mac")
            case .unavailable(.appleIntelligenceNotEnabled):
                return Readiness(canAnswer: false, installed: false, message: "Turn on Apple Intelligence in System Settings")
            case .unavailable(.modelNotReady):
                return Readiness(canAnswer: false, installed: true, message: "macOS is still downloading the model. Keep the Mac on power and Wi-Fi.")
            case .unavailable(.deviceNotEligible):
                return Readiness(canAnswer: false, installed: false, message: "This Mac cannot run Apple's on-device model")
            case .unavailable:
                return Readiness(canAnswer: false, installed: false, message: "Apple's on-device model is unavailable")
            }
        }
        #endif
        return Readiness(canAnswer: false, installed: false, message: "Requires macOS 26 with Apple Intelligence")
    }

    static func generate(input: Data, schema: String, systemPrompt: String, timeout: Double) async throws -> AIJSONResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard readiness().canAnswer else { throw AIProviderError.unavailable }
            guard let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else { throw AIProviderError.invalidInput }
            let generation = try GenerationSchema(root: dynamicSchema(object, name: "Response"), dependencies: [])
            let prompt = String(decoding: input, as: UTF8.self)
            let start = Date()
            let content = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // Content transformation guardrails fit summarizing and answering over the person's own text.
                    let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                    let session = LanguageModelSession(model: model, instructions: systemPrompt)
                    do { return try await session.respond(to: prompt, schema: generation).content.jsonString }
                    catch { throw mapped(error) }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(min(180, max(5, timeout))))
                    throw AIProviderError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw AIProviderError.invalidResponse }
                return first
            }
            guard var payload = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else {
                throw AIProviderError.invalidResponse
            }
            // Optional fields stand in for JSON null; callers expect every required key.
            for key in object["required"] as? [String] ?? [] where payload[key] == nil { payload[key] = NSNull() }
            let usage = UsageEntry(provider: AIProviderKind.apple.rawValue, model: "on-device", durationSeconds: Date().timeIntervalSince(start))
            return AIJSONResult(payload: payload, usage: usage)
        }
        #endif
        throw AIProviderError.unavailable
    }

    #if canImport(FoundationModels)
    /// The subset of JSON Schema Reprise writes: objects, arrays with a maximum, string enums and
    /// nullable fields, which become optional properties.
    @available(macOS 26.0, *)
    static func dynamicSchema(_ json: [String: Any], name: String) -> DynamicGenerationSchema {
        let types = (json["type"] as? [String]) ?? (json["type"] as? String).map { [$0] } ?? []
        if let values = json["enum"] as? [Any] {
            return DynamicGenerationSchema(name: name, anyOf: values.compactMap { $0 as? String })
        }
        switch types.first(where: { $0 != "null" }) {
        case "object":
            let properties = json["properties"] as? [String: Any] ?? [:]
            let required = json["required"] as? [String] ?? []
            let order = required + properties.keys.sorted().filter { !required.contains($0) }
            return DynamicGenerationSchema(name: name, properties: order.compactMap { key in
                guard let value = properties[key] as? [String: Any] else { return nil }
                let nullable = ((value["type"] as? [String])?.contains("null") ?? false)
                    || ((value["enum"] as? [Any])?.contains { $0 is NSNull } ?? false)
                return DynamicGenerationSchema.Property(name: key, schema: dynamicSchema(value, name: name + "_" + key),
                                                        isOptional: nullable || !required.contains(key))
            })
        case "array":
            let items = json["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: dynamicSchema(items, name: name + "_item"), maximumElements: json["maxItems"] as? Int)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    @available(macOS 26.0, *)
    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return AIProviderError.cancelled }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return AIProviderError.contextTooLarge
            case .guardrailViolation, .refusal: return AIProviderError.refused
            default: return AIProviderError.providerFailed
            }
        }
        let description = String(describing: error).lowercased()
        if description.contains("context") { return AIProviderError.contextTooLarge }
        if description.contains("guardrail") || description.contains("refus") { return AIProviderError.refused }
        return AIProviderError.providerFailed
    }
    #endif
}
