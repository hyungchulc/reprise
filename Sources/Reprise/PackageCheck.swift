import Foundation
import RepriseCore

enum PackageCheck {
    /// Runs before AppModel initialization; never opens a vault or requests permissions.
    static func run() -> Never {
        let bundle = Bundle.main
        let root = bundle.bundleURL
        let files = ["Contents/Resources/AppIcon.icns", "Contents/Resources/LICENSE",
            "Contents/Resources/THIRD_PARTY_NOTICES.md", "Contents/Frameworks/Sparkle.framework/Sparkle"]
        let helper = root.appendingPathComponent("Contents/MacOS/RepriseMCP")
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
        let valid = root.pathExtension == "app" && files.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        } && FileManager.default.isExecutableFile(atPath: helper.path)
            && Data(base64Encoded: key)?.count == 32 && feed?.scheme == "https"
            && bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true
            && bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true
        let result: [String: Any] = ["valid": valid,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "vault_opened": false, "permissions_requested": false]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) {
            FileHandle.standardOutput.write(data + Data([0x0a]))
        }
        exit(valid ? 0 : 1)
    }
}

enum VaultCheck {
    /// Opens the library at `path` as the app would: takes its key from the login keychain (or
    /// creates one that Reprise and its MCP helper can read), converts a library from before
    /// encryption and seals its media. Prints counts only, never memory content.
    static func run(path: String) -> Never {
        var result: [String: Any] = [:]
        var valid = false
        do {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let keys = try AppModel.libraryKeys(root: root)
            let store = try MomentStore(root: root, keys: keys)
            if store.convertedFromPlaintext { try MCPAccess.adoptUnsigned(root: root, keys: keys) }
            let referenced = try runBlocking { try await store.referencedMedia() }
            var sealed = 0, failure: String?
            while true {
                let progress = VaultMigration.sealLegacyFiles(root: root, cipher: keys.cipher, referenced: referenced)
                sealed += progress.sealed; failure = failure ?? progress.failure
                if !progress.remaining { break }
            }
            let stats = try runBlocking { try await store.stats() }
            result = ["converted": store.convertedFromPlaintext, "memories": stats.momentCount, "sealed_files": sealed,
                      "database_encrypted": MomentStore.isEncryptedLibrary(root: root),
                      "mcp_enabled": (try? MCPAccess.load(root: root, keys: keys).enabled) ?? false]
            if let failure { result["failure"] = failure }
            valid = failure == nil
        } catch { result["error"] = error.localizedDescription }
        result["valid"] = valid
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) {
            FileHandle.standardOutput.write(data + Data([0x0a]))
        }
        exit(valid ? 0 : 1)
    }

    private static func runBlocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<T, Error>!
        Task.detached { outcome = await Result { try await work() }; done.signal() }
        done.wait()
        return try outcome.get()
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
