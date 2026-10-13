import Foundation

public struct AIAccountStatus: Sendable {
    public let signedIn: Bool?
    public let message: String
}

public extension AIClient {
    func accountStatus(configuration: AIProviderConfiguration) async -> AIAccountStatus {
        guard let executable = AICommand.executable(configuration) else {
            return AIAccountStatus(signedIn: false, message: "CLI not installed")
        }
        do {
            let arguments: [String]
            switch configuration.provider {
            case .codex: arguments = ["login", "status"]
            case .claude: arguments = ["auth", "status", "--json"]
            case .grok: arguments = ["models"]
            }
            let result = try await AIProcessRunner.run(executable: executable, arguments: arguments, input: Data(), timeout: 8, outputLimit: 16 * 1024)
            if configuration.provider == .claude,
               let value = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
               let loggedIn = value["loggedIn"] as? Bool {
                let method = (value["authMethod"] as? String ?? "").lowercased()
                if method.contains("api") || method.contains("console") {
                    return AIAccountStatus(signedIn: false, message: "API billing sign-in found. Use Claude subscription sign-in.")
                }
                return AIAccountStatus(signedIn: loggedIn, message: loggedIn ? "Signed in to Claude" : "Not signed in")
            }
            if configuration.provider == .codex {
                let subscription = result.subscriptionLogin
                return AIAccountStatus(signedIn: subscription, message: subscription ? "Signed in with ChatGPT" : "ChatGPT subscription sign-in required")
            }
            if configuration.provider == .grok {
                let text = String(decoding: result.stdout, as: UTF8.self)
                if result.exitCode == 0 && text.contains("You are logged in with grok.com.") {
                    return AIAccountStatus(signedIn: true, message: "Signed in with grok.com")
                }
            }
        } catch { }
        return AIAccountStatus(signedIn: nil, message: "Could not verify sign-in")
    }

    nonisolated func loginCommand(configuration: AIProviderConfiguration) -> (executable: URL, arguments: [String])? {
        guard let executable = AICommand.executable(configuration) else { return nil }
        let arguments: [String]
        switch configuration.provider {
        case .codex: arguments = ["login"]
        case .claude: arguments = ["auth", "login", "--claudeai"]
        case .grok: arguments = ["login", "--oauth"]
        }
        return (executable, arguments)
    }
}
