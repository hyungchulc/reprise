import Foundation

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
