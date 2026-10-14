import AppKit
import RepriseCore
import RepriseMCPKit
import SwiftUI

/// Meeting Assistant settings: how it opens, who answers, and how it listens.
struct AssistantSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: MeetingAssistant
    @StateObject private var access = OpenAIAccessCheck()
    @StateObject private var device = OnDeviceCaptions()
    private var settings: AssistantPreferences { model.preferences.assistant }

    var body: some View {
        Section("Meeting Assistant") { control }
        Section("Answers") { answers }
        Section("Web Search") { AssistantWebSettings(model: model) }
        Section("MCP Tools") { AssistantServerList(model: model) }
        Section("Listening") { listening }
        if settings.listening != .onDevice || settings.answers != .provider {
            Section("OpenAI") { OpenAIAccessRow(model: model, access: access, purpose: "The meeting assistant") }
        }
        if settings.listening != .openAI {
            Section("On This Mac") { AssistantOnDeviceStatus(device: device, spoken: spokenOnDevice) }
        }
    }

    /// The language this Mac listens for: the one chosen here, or else the first transcription language.
    private var spokenOnDevice: String { settings.spoken.isEmpty ? model.preferences.speechLocales.first ?? "" : settings.spoken }

    @ViewBuilder private var control: some View {
        LabeledContent("Assistant") {
            HStack(spacing: 8) {
                AssistantRunState(assistant: assistant)
                Button(assistant.isRunning ? "Stop" : "Start") { Task { await model.toggleAssistant() } }
            }
        }
        ShortcutSettings(shortcut: model.assistantShortcut, title: "Meeting Assistant")
        ShortcutSettings(shortcut: model.answerShortcut, title: "Answer Last Question")
        Toggle("Open with meeting recordings", isOn: $model.preferences.assistant.openWithMeetings)
        Text("The assistant hears you through the microphone and the others through Mac audio, and answers in a small window that floats beside the meeting without taking focus. What it hears is not saved; record the meeting to keep a transcript.")
            .repriseFont(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var answers: some View {
        Toggle("Answer the others' questions as they ask them", isOn: $model.preferences.assistant.autoAnswer)
        Toggle("Search my memories", isOn: $model.preferences.assistant.useMemories)
        Picker("Answers by", selection: $model.preferences.assistant.answers) {
            ForEach(AssistantAnswerEngine.allCases) { Text($0.title).tag($0) }
        }
        Text(settings.answers.about).repriseFont(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var listening: some View {
        Picker("Spoken language", selection: $model.preferences.assistant.spoken) {
            Text("Detect automatically").tag("")
            ForEach(device.spokenLanguages(including: settings.spoken)) { Text($0.name).tag($0.id) }
        }
        .task { await device.load() }
        Picker("Listen with", selection: $model.preferences.assistant.listening) {
            ForEach(CaptionEngine.allCases) { Text($0.title).tag($0) }
        }
        Text(listeningAbout).repriseFont(.caption).foregroundStyle(.secondary)
    }

    private var listeningAbout: String {
        let fallback = settings.spoken.isEmpty && !spokenOnDevice.isEmpty
            ? " This Mac listens for \(Locale.current.localizedString(forIdentifier: spokenOnDevice) ?? spokenOnDevice), the first of the transcription languages in Audio."
            : ""
        switch settings.listening {
        case .automatic:
            return "OpenAI when the account below works, and this Mac otherwise. OpenAI recognizes the spoken language by itself." + fallback
        case .openAI:
            return "OpenAI recognizes the spoken language by itself and writes what is said within about two seconds. Audio from both sides goes to OpenAI while the assistant is open."
        case .onDevice:
            return "Speech is recognized on this Mac and no audio leaves it. This needs macOS 26." + fallback
        }
    }
}

extension AssistantAnswerEngine {
    var about: String {
        switch self {
        case .automatic:
            "OpenAI answers within about a second when the account below works. Otherwise the provider chosen in AI & Models answers, which takes longer."
        case .openAI:
            "OpenAI's Realtime model starts answering within about a second and searches your memories as it answers. The question, the last few minutes of the conversation and the memories it finds go to OpenAI."
        case .provider:
            "The provider chosen in AI & Models answers from the last few minutes of the conversation and from memories that match the question's words. With Apple on-device or Ollama, nothing leaves this Mac. Answers take longer than with OpenAI."
        }
    }
}

private struct AssistantRunState: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        if let problem = assistant.problem {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(problem).lineLimit(3)
        } else if assistant.isRunning {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").foregroundStyle(.green)
            Text("On")
        } else {
            Text("Off").foregroundStyle(.secondary)
        }
    }
}

/// Whether this Mac can listen in the chosen language, and what is missing if not.
private struct AssistantOnDeviceStatus: View {
    @ObservedObject var device: OnDeviceCaptions
    let spoken: String
    var body: some View {
        if !OnDeviceCaptions.supported {
            Label("Listening on this Mac needs macOS 26 or later. On this version, the assistant listens with OpenAI.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        } else if spoken.isEmpty {
            Label("This Mac cannot detect the spoken language by itself. To listen on this Mac, choose the spoken language above.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("Speech recognition") { AvailabilityText(availability: device.recognition, starting: "the assistant starts") }
        }
        Text("Speech models download once from Apple and stay on this Mac.")
            .repriseFont(.caption).foregroundStyle(.secondary)
            .task(id: spoken) { await device.check(spoken: spoken, target: nil) }
    }
}

/// Whether answers may search the web, and through what.
private struct AssistantWebSettings: View {
    @ObservedObject var model: AppModel
    private var settings: AssistantPreferences { model.preferences.assistant }

    var body: some View {
        Toggle("Search the web", isOn: $model.preferences.assistant.webSearch)
        if settings.webSearch {
            let tools = model.webSearchTools()
            Picker("Search with", selection: $model.preferences.assistant.webRoute) {
                ForEach(WebSearchRoute.allCases) { route in Text(title(route, tools)).tag(route) }
            }
            Text(about(WebSearch.resolve(settings.webRoute, tools))).repriseFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ route: WebSearchRoute, _ tools: WebSearch.Tools) -> String {
        guard route == .automatic else { return route.title + (WebSearch.ready(route, tools) ? "" : " (not set up)") }
        return "Automatic" + (WebSearch.resolve(.automatic, tools).map { " (\($0.title))" } ?? " (none set up)")
    }

    private func about(_ route: WebSearchRoute?) -> String {
        let when = "OpenAI searches when the web helps; with another provider, Reprise searches when your memories have nothing."
        switch route {
        case .codex?, .claude?:
            return "Searches on \(route == .codex ? "OpenAI" : "Anthropic")'s side through the CLI you sign in to, within your plan's limits. A search takes about ten seconds. " + when
        case .openAIAPI?, .geminiAPI?, .anthropicAPI?:
            return "Searches through your API key, which the provider bills per search on top of tokens. A search takes a few seconds. " + when
        default:
            return "No web search is set up. Install Codex or Claude Code and sign in, or add an OpenAI, Gemini or Anthropic API key in AI & Models."
        }
    }
}

/// The person's MCP servers, each with its own switch.
private struct AssistantServerList: View {
    @ObservedObject var model: AppModel
    @State private var editing: MCPServerSetting?

    var body: some View {
        ForEach(model.preferences.assistant.servers) { server in
            HStack(spacing: 10) {
                Toggle(isOn: enabled(server.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                        Text(server.isCommand ? server.command : server.url).repriseFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button("Edit") { editing = server }
            }
        }
        HStack {
            Button("Add Server...", systemImage: "plus") { editing = MCPServerSetting() }
            Spacer()
        }
        Text("MCP servers give the assistant more tools, such as a search engine, your notes or a calendar. A command server runs as you, the way other MCP apps start it, so add only servers you trust. The assistant calls the tools that are on by itself while it answers, also because of something said in the meeting, so tools that change things start off. Tools work when OpenAI answers.")
            .repriseFont(.caption).foregroundStyle(.secondary)
            .sheet(item: $editing) { server in
                MCPServerEditor(server: server, isNew: !model.preferences.assistant.servers.contains { $0.id == server.id }) { saved in
                    if let index = model.preferences.assistant.servers.firstIndex(where: { $0.id == saved.id }) {
                        model.preferences.assistant.servers[index] = saved
                    } else {
                        model.preferences.assistant.servers.append(saved)
                    }
                } remove: {
                    MCPServerKeychain.remove(server.id)
                    model.preferences.assistant.servers.removeAll { $0.id == server.id }
                }
                .repriseAppearance(model.preferences)
            }
    }

    private func enabled(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.preferences.assistant.servers.first { $0.id == id }?.enabled ?? false }, set: { value in
            if let index = model.preferences.assistant.servers.firstIndex(where: { $0.id == id }) { model.preferences.assistant.servers[index].enabled = value }
        })
    }
}

/// Adds or edits one MCP server, checks that it starts, and picks its tools.
struct MCPServerEditor: View {
    @State private var server: MCPServerSetting
    let isNew: Bool
    let save: (MCPServerSetting) -> Void
    let remove: () -> Void
    @State private var byCommand: Bool
    @State private var environment: String
    @State private var token: String
    @State private var tools: [MCPToolInfo]?
    @State private var checking = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(server: MCPServerSetting, isNew: Bool, save: @escaping (MCPServerSetting) -> Void, remove: @escaping () -> Void) {
        let secrets = isNew ? MCPServerSecrets() : MCPServerKeychain.load(server.id)
        _server = State(initialValue: server)
        _byCommand = State(initialValue: server.isCommand || server.url.isEmpty)
        _environment = State(initialValue: secrets.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _token = State(initialValue: secrets.token)
        self.isNew = isNew; self.save = save; self.remove = remove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add MCP Server" : "Edit MCP Server").font(.headline)
            Form {
                TextField("Name", text: $server.name, prompt: Text("Web search"))
                Picker("Connects by", selection: $byCommand) {
                    Text("Command").tag(true)
                    Text("Address").tag(false)
                }.pickerStyle(.segmented)
                if byCommand {
                    TextField("Command", text: $server.command, prompt: Text("npx -y @modelcontextprotocol/server-everything"))
                    TextField("Environment", text: $environment, prompt: Text("API_KEY=value, one per line"), axis: .vertical).lineLimit(1...3)
                } else {
                    TextField("Address", text: $server.url, prompt: Text("https://example.com/mcp"))
                    SecureField("Bearer token", text: $token, prompt: Text("Optional"))
                }
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: byCommand ? 190 : 165)
            toolList
            if let problem { Text(problem).repriseFont(.caption).foregroundStyle(.orange).lineLimit(4) }
            HStack {
                if !isNew { Button("Remove", role: .destructive) { remove(); dismiss() } }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check") { Task { await check() } }.disabled(checking || !complete)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store() }.keyboardShortcut(.defaultAction).disabled(!complete)
            }
        }
        .padding(20).frame(width: 540)
    }

    @ViewBuilder private var toolList: some View {
        if let tools {
            Text(tools.isEmpty ? "The server offers no tools." : "Tools the assistant may use").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tools) { tool in
                        Toggle(isOn: Binding(get: { server.allows(tool) }, set: { server.toolChoices[tool.name] = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name + (tool.readOnly ? "" : "  · may change things")).font(.callout)
                                if !tool.description.isEmpty { Text(tool.description).repriseFont(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
        } else {
            Text("Check starts the server and lists its tools, so you can choose which ones the assistant may use.")
                .repriseFont(.caption).foregroundStyle(.secondary)
        }
    }

    private var complete: Bool {
        !server.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !(byCommand ? server.command : server.url).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var current: (MCPServerSetting, MCPServerSecrets) {
        var setting = server
        if byCommand { setting.url = "" } else { setting.command = "" }
        var variables: [String: String] = [:]
        for line in environment.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { variables[name] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces) }
        }
        return (setting, MCPServerSecrets(environment: byCommand ? variables : [:], token: byCommand ? "" : token))
    }

    private func check() async {
        checking = true; problem = nil
        let (setting, secrets) = current
        let hub = MCPToolHub()
        do {
            tools = try await hub.connect(setting, secrets: secrets)
        } catch {
            tools = nil
            problem = error.localizedDescription
        }
        await hub.disconnectAll()
        checking = false
    }

    private func store() {
        let (setting, secrets) = current
        do {
            try MCPServerKeychain.save(secrets, for: setting.id, name: setting.name)
            save(setting)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
