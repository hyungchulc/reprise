import Foundation

public struct AIAccountStatus: Sendable {
    public let signedIn: Bool?
    public let message: String
}

public extension AIClient {
    func accountStatus(configuration: AIProviderConfiguration) async -> AIAccountStatus {
        switch configuration.provider {
        case .apple:
            let readiness = OnDeviceModel.readiness()
            return AIAccountStatus(signedIn: readiness.canAnswer, message: readiness.canAnswer ? "No account needed, runs on this Mac" : readiness.message)
        case .ollama:
            let running = await Ollama.version() != nil
            return AIAccountStatus(signedIn: running, message: running ? "No account needed, runs on this Mac" : "Start Ollama to use it")
        case .opencode:
            let installed = AICommand.executable(configuration) != nil
            return AIAccountStatus(signedIn: installed ? true : false, message: installed ? "Free models, no sign-in needed" : "CLI not installed")
        case .openAIAPI, .anthropicAPI, .geminiAPI:
            guard let vendor = configuration.provider.apiKeyProvider, let key = APIKeys.load(vendor) else {
                return AIAccountStatus(signedIn: false, message: "No API key saved")
            }
            do {
                // Listing models proves the key without sending a prompt.
                _ = try await ProviderAPI.listModels(configuration.provider, key: key)
                return AIAccountStatus(signedIn: true, message: "API key works")
            } catch {
                return AIAccountStatus(signedIn: false, message: error.localizedDescription)
            }
        default: break
        }
        guard let executable = AICommand.executable(configuration) else {
            return AIAccountStatus(signedIn: false, message: "CLI not installed")
        }
        do {
            let arguments: [String]
            switch configuration.provider {
            case .codex: arguments = ["login", "status"]
            case .claude: arguments = ["auth", "status", "--json"]
            case .grok, .gemini: arguments = ["models"]
            case .cursor: arguments = ["status"]
            default: arguments = ["--help"]
            }
            let result = try await AIProcessRunner.run(executable: executable, arguments: arguments, input: Data(),
                                                       timeout: configuration.provider == .gemini ? 20 : 8, outputLimit: 16 * 1024)
            let text = String(decoding: result.stdout, as: UTF8.self)
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
                if result.exitCode == 0 && text.contains("You are logged in with grok.com.") {
                    return AIAccountStatus(signedIn: true, message: "Signed in with grok.com")
                }
            }
            if configuration.provider == .gemini {
                // Listing models needs a working Google sign-in; nothing is sent to a model.
                if result.exitCode == 0 && !AIClient.geminiModels(text).isEmpty {
                    return AIAccountStatus(signedIn: true, message: "Signed in with Google")
                }
                return AIAccountStatus(signedIn: false, message: "Google sign-in required")
            }
            if configuration.provider == .cursor {
                if text.contains("Logged in") { return AIAccountStatus(signedIn: true, message: "Signed in to Cursor") }
                if text.lowercased().contains("not logged in") { return AIAccountStatus(signedIn: false, message: "Not signed in") }
            }
        } catch { }
        return AIAccountStatus(signedIn: nil, message: "Could not verify sign-in")
    }

    nonisolated func loginCommand(configuration: AIProviderConfiguration) -> (executable: URL, arguments: [String])? {
        guard configuration.provider.hasSignIn, let executable = AICommand.executable(configuration) else { return nil }
        let arguments: [String]
        switch configuration.provider {
        case .codex: arguments = ["login"]
        case .claude: arguments = ["auth", "login", "--claudeai"]
        case .grok: arguments = ["login", "--oauth"]
        case .cursor: arguments = ["login"]
        // Antigravity has no login command; its interactive start asks for a Google sign-in.
        default: arguments = []
        }
        return (executable, arguments)
    }
}

public extension AIProviderKind {
    /// The vendor's own installer, run in Terminal so the person sees each step. Nil when there is
    /// nothing to install: Apple's model comes with macOS and is turned on in System Settings.
    var installScript: String? {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "if command -v npm >/dev/null 2>&1; then npm install -g @openai/codex; else brew install --cask codex; fi"
        case .grok: "curl -fsSL https://x.ai/cli/install.sh | bash"
        case .gemini: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        case .cursor: "curl -fsSL https://cursor.com/install | bash"
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        case .ollama: "if command -v brew >/dev/null 2>&1; then brew install --cask ollama-app && open -a Ollama; else open https://ollama.com/download/mac; fi"
        case .apple, .openAIAPI, .anthropicAPI, .geminiAPI: nil
        }
    }
}
