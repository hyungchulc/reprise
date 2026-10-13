import Foundation
import Security

public struct SignedAppUpdate: Sendable {
    public let source: URL
    public let version: String
    public let build: String
    public let requirement: String

    public static func check(source: URL, installed: URL) throws -> SignedAppUpdate? {
        guard source.standardizedFileURL != installed.standardizedFileURL,
              source.pathExtension == "app", installed.pathExtension == "app" else { return nil }
        let installedCode = try code(at: installed)
        var information: CFDictionary?
        try validate(SecCodeCopySigningInformation(installedCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            throw UpdateError("A development-signed installation is required before updating.")
        }
        var requirement: SecRequirement?
        try validate(SecCodeCopyDesignatedRequirement(installedCode, [], &requirement))
        guard let requirement else { throw UpdateError("The installed app has no signing requirement.") }
        try validate(SecStaticCodeCheckValidity(try code(at: source), SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement))
        var expression: CFString?
        try validate(SecRequirementCopyString(requirement, [], &expression))
        guard let expression, let current = Bundle(url: installed), let incoming = Bundle(url: source),
              current.bundleIdentifier == incoming.bundleIdentifier,
              let build = incoming.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let old = current.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              build.range(of: #"^[0-9]+([.][0-9]+)*$"#, options: .regularExpression) != nil else {
            throw UpdateError("The update's app identity or version is invalid.")
        }
        guard build.compare(old, options: .numeric) == .orderedDescending else { return nil }
        return SignedAppUpdate(source: source, version: incoming.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? build,
                               build: build, requirement: expression as String)
    }

    private static func code(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        try validate(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw UpdateError("Could not inspect the app signature.") }
        return code
    }

    private static func validate(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw UpdateError("Update signature verification failed (\(status)).")
        }
    }
}

public struct UpdateError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
