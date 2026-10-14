import AppKit
import RepriseCore
import SwiftUI

/// Audio settings: which engine transcribes meetings, its model, and speaker labels.
struct TranscriptionSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var models: LocalSpeechModels
    @StateObject private var access = OpenAIAccessCheck()
    @StateObject private var google = GeminiAccessCheck()
    private var engine: TranscriptionEngine { model.preferences.transcriptionEngine }

    var body: some View {
        Picker("Engine", selection: $model.preferences.transcriptionEngine) {
            ForEach(TranscriptionEngine.allCases) { Text($0.title).tag($0) }
        }
        Text(engine.about).repriseFont(.caption).foregroundStyle(.secondary)
        switch engine {
        case .apple: EmptyView()
        case .whisperKit: whisper
        case .openAI: openAI
        case .gemini: GeminiTranscriptionSettings(model: model, check: google)
        }
    }

    @ViewBuilder private var whisper: some View {
        Picker("Model", selection: $model.preferences.whisperModel) {
            ForEach(WhisperModel.all) { option in
                Text("\(option.name), \(ByteCountFormatter.string(fromByteCount: Int64(option.megabytes) * 1_000_000, countStyle: .file))").tag(option.id)
            }
        }
        if let note = WhisperModel.all.first(where: { $0.id == model.preferences.whisperModel })?.note {
            Text(note).repriseFont(.caption).foregroundStyle(.secondary)
        }
        ModelDownloadRow(title: WhisperModel.named(model.preferences.whisperModel), state: models.state(of: model.preferences.whisperModel),
                         size: models.sizes[model.preferences.whisperModel],
                         download: { models.download(model.preferences.whisperModel) },
                         cancel: { models.cancel(model.preferences.whisperModel) },
                         delete: { models.delete(model.preferences.whisperModel) })
        let others = WhisperModel.all.filter { $0.id != model.preferences.whisperModel && models.isReady($0.id) }
        ForEach(others) { other in
            LabeledContent(other.name) {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: models.sizes[other.id] ?? 0, countStyle: .file)).foregroundStyle(.secondary)
                    Button("Delete", role: .destructive) { models.delete(other.id) }
                }
            }
        }
    }

    @ViewBuilder private var openAI: some View {
        Picker("Model", selection: $model.preferences.openAITranscriptionModel) {
            ForEach(OpenAITranscriptionModel.all) { Text($0.name).tag($0.id) }
            if !OpenAITranscriptionModel.all.contains(where: { $0.id == model.preferences.openAITranscriptionModel }) {
                Text(model.preferences.openAITranscriptionModel).tag(model.preferences.openAITranscriptionModel)
            }
        }
        if let note = OpenAITranscriptionModel.all.first(where: { $0.id == model.preferences.openAITranscriptionModel })?.note {
            Text(note).repriseFont(.caption).foregroundStyle(.secondary)
        }
        OpenAIAccessRow(model: model, access: access, purpose: "Transcription")
    }
}

/// How Reprise reaches OpenAI, with a check that it works. Shared by every OpenAI feature.
struct OpenAIAccessRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var access: OpenAIAccessCheck
    let purpose: String
    var body: some View {
        Picker("Account", selection: $model.preferences.openAIAccess) {
            ForEach(OpenAIAccess.allCases) { Text($0.title).tag($0) }
        }
        if model.preferences.openAIAccess == .apiKey {
            APIKeyField(provider: .openAI) { access.check(.apiKey, codexPath: model.codexPath) }
        }
        AccessStatusRow(state: access.state)
        HStack {
            if model.preferences.openAIAccess == .chatGPT {
                Button(ChatGPTSignIn.codexExecutable(configured: model.codexPath) == nil ? "Install Codex" : "Sign In with ChatGPT", systemImage: "person.crop.circle") {
                    model.signInToCodex()
                }
            }
            Spacer()
            Button("Check", systemImage: "arrow.clockwise") { access.check(model.preferences.openAIAccess, codexPath: model.codexPath) }
                .disabled(access.state == .checking)
        }
        Text(model.preferences.openAIAccess == .chatGPT
             ? "\(purpose) and Reprise's other OpenAI features use the ChatGPT plan the Codex CLI on this Mac is signed in with, and count toward that plan's limits. The sign-in stays with Codex; Reprise asks Codex for it each time and never stores it."
             : "\(purpose) and Reprise's other OpenAI features are billed to the OpenAI API account of the key, which stays in this Mac's login keychain.")
            .repriseFont(.caption).foregroundStyle(.secondary)
            .task(id: model.preferences.openAIAccess) { access.check(model.preferences.openAIAccess, codexPath: model.codexPath) }
    }
}

/// Whether an account check passed, with the service's own words when it did not.
struct AccessStatusRow: View {
    let state: OpenAIAccessCheck.State
    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 8) {
                switch state {
                case .checking: ProgressView().controlSize(.small); Text("Checking...").foregroundStyle(.secondary)
                case .ready(let message): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(message)
                case .unavailable(let message): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(message).lineLimit(3)
                case .unknown: Text("Not checked").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Gemini's account, model and status for transcription.
struct GeminiTranscriptionSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var check: GeminiAccessCheck
    private var account: GeminiAccess { model.preferences.geminiAccess }

    var body: some View {
        Picker("Account", selection: $model.preferences.geminiAccess) {
            ForEach(GeminiAccess.allCases) { Text($0.title).tag($0) }
        }
        // Model names differ between the plan and the API, so a new account starts on Automatic.
        .onChange(of: model.preferences.geminiAccess) { model.preferences.geminiTranscriptionModel = "" }
        if account == .apiKey {
            APIKeyField(provider: .gemini) { check.check(.apiKey, path: model.geminiPath) }
        }
        Picker("Model", selection: $model.preferences.geminiTranscriptionModel) {
            Text(check.automatic.map { "Automatic (\($0))" } ?? "Automatic").tag("")
            ForEach(check.models) { Text($0.name).tag($0.id) }
            let saved = model.preferences.geminiTranscriptionModel
            if !saved.isEmpty, !check.models.contains(where: { $0.id == saved }) { Text(saved).tag(saved) }
        }
        AccessStatusRow(state: check.state)
        HStack {
            if account == .subscription {
                Button(check.installed ? "Sign In with Google" : "Install Antigravity", systemImage: "person.crop.circle") { model.signInToAntigravity() }
            }
            Spacer()
            Button("Check", systemImage: "arrow.clockwise") { check.check(account, path: model.geminiPath) }
                .disabled(check.state == .checking)
        }
        Text(account == .subscription
             ? "Transcription uses the Google AI plan that Antigravity on this Mac is signed in with, and counts toward that plan's limits. It takes a few minutes for each 20 minutes of a recording. Antigravity reads each part from a private temporary copy that is deleted right after."
             : "Transcription is billed to the Gemini API account of the key, which stays in this Mac's login keychain.")
            .repriseFont(.caption).foregroundStyle(.secondary)
            .task(id: account) { check.check(account, path: model.geminiPath) }
    }
}

/// Whether Gemini can transcribe with the chosen account, and the Gemini models it offers. No
/// audio or prompt is sent.
@MainActor
final class GeminiAccessCheck: ObservableObject {
    @Published private(set) var state = OpenAIAccessCheck.State.unknown
    @Published private(set) var models: [AIModelOption] = []
    @Published private(set) var installed = true
    private var access = GeminiAccess.subscription
    private var task: Task<Void, Never>?

    /// The model Automatic picks from the list, by name.
    var automatic: String? {
        let id = access == .subscription ? GeminiTranscription.automaticModel(models) : ProviderAPI.automaticModel(.geminiAPI, from: models.map(\.id))
        return id.flatMap { id in models.first { $0.id == id }?.name }
    }

    func check(_ access: GeminiAccess, path: String?) {
        task?.cancel()
        state = .checking
        task = Task {
            let client = AIClient()
            let configuration = access == .subscription ? AIProviderConfiguration(provider: .gemini, executablePath: path)
                                                        : AIProviderConfiguration(provider: .geminiAPI)
            let account = await client.accountStatus(configuration: configuration)
            let listed = account.signedIn == true ? await client.models(configuration: configuration).filter { $0.id.hasPrefix("gemini-") } : []
            guard !Task.isCancelled else { return }
            installed = access == .apiKey || account.message != "CLI not installed"
            self.access = access
            models = listed
            if account.signedIn == true {
                state = .ready(access == .subscription ? "Ready with your Google AI plan" : "Ready with the API key")
            } else {
                state = .unavailable(access == .subscription && !installed ? "Antigravity is not installed." : account.message)
            }
        }
    }
}

/// Whether OpenAI accepts the chosen account, found by starting a session that is never used.
@MainActor
final class OpenAIAccessCheck: ObservableObject {
    enum State: Equatable { case unknown, checking, ready(String), unavailable(String) }
    @Published private(set) var state = State.unknown
    private var task: Task<Void, Never>?

    func check(_ access: OpenAIAccess, codexPath: String?) {
        task?.cancel()
        state = .checking
        task = Task {
            do {
                let credential = try await OpenAICredential.resolve(access, codexPath: codexPath)
                _ = try await OpenAIRealtime.clientSecret(credential, session: OpenAIRealtime.transcriptionSession(model: OpenAITranscriptionModel.standard, language: nil, vad: true))
                guard !Task.isCancelled else { return }
                state = .ready(access == .chatGPT ? "Ready with ChatGPT" : "Ready with the API key")
            } catch {
                guard !Task.isCancelled else { return }
                state = .unavailable(error.localizedDescription)
            }
        }
    }
}

/// A downloadable model: its state, size, and the one action that fits.
struct ModelDownloadRow: View {
    let title: String
    let state: LocalSpeechModels.State
    let size: Int64?
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                switch state {
                case .absent:
                    Button("Download", systemImage: "arrow.down.circle", action: download)
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 110)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel", action: cancel)
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("Preparing for this Mac...").foregroundStyle(.secondary)
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Ready").foregroundStyle(.secondary)
                    Button("Delete", role: .destructive, action: delete)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                    Button("Try Again", action: download)
                }
            }
        }
        if case .failed(let message) = state { Text(message).repriseFont(.caption).foregroundStyle(.secondary).lineLimit(3) }
        if case .preparing = state {
            Text("The first time, a model is compiled for this Mac's Neural Engine, which can take a few minutes.")
                .repriseFont(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SpeakerLabelSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var models: LocalSpeechModels
    var body: some View {
        Toggle("Label speakers", isOn: $model.preferences.speakerLabels)
        if model.preferences.speakerLabels {
            ModelDownloadRow(title: "Speaker model", state: models.speakers, size: models.sizes["speakers"],
                             download: models.downloadSpeakers, cancel: { models.cancel("speakers") }, delete: models.deleteSpeakers)
        }
        Text(model.preferences.transcriptionEngine == .gemini
             ? "Gemini tells the voices apart itself in recordings up to 20 minutes and labels each part, such as Speaker 1. Longer recordings are labeled on this Mac with the speaker model, about 30 MB, which downloads once. Click a speaker's name in a transcript to rename them."
             : "Finds who is speaking, on this Mac, with every engine, and labels each part, such as Speaker 1. Click a speaker's name in a transcript to rename them. The speaker model is about 30 MB and downloads once; recordings up to two hours are labeled.")
            .repriseFont(.caption).foregroundStyle(.secondary)
    }
}

/// API keys for people who pay per use instead of a subscription. Keys stay in the login keychain.
struct APIKeySettings: View {
    var body: some View {
        ForEach(APIKeySettings.offered) { APIKeyField(provider: $0) }
        Text("For a pay-per-use API account instead of a subscription. Each key answers searches, summaries and the meeting assistant when its API is the provider above. An OpenAI key also serves transcription, live captions and the meeting assistant when their OpenAI account is set to the API key. Use is billed by the provider to the key's account.")
            .repriseFont(.caption).foregroundStyle(.secondary)
    }
    /// Providers whose keys some feature uses.
    static let offered: [APIKeyProvider] = APIKeyProvider.allCases
}

/// One provider's key: saved, or a field to paste it into.
struct APIKeyField: View {
    let provider: APIKeyProvider
    /// Runs after the key is saved or removed.
    var changed: () -> Void = {}
    @State private var draft = ""
    @State private var stored = false
    @State private var error: String?
    var body: some View {
        LabeledContent("\(provider.displayName) API key") {
            HStack(spacing: 8) {
                if stored {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved in Keychain").foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { APIKeys.remove(provider); announce() }
                } else {
                    SecureField("API key", text: $draft, prompt: Text("Paste key")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 200).onSubmit(save)
                    Button("Save", action: save).disabled(draft.isEmpty)
                    Link(destination: provider.consoleURL) { Image(systemName: "arrow.up.right.square") }.help("Get a \(provider.displayName) API key")
                }
            }
        }
        .onAppear { stored = APIKeys.has(provider) }
        // The same key can show in more than one place on a page.
        .onReceive(NotificationCenter.default.publisher(for: Self.keysChanged)) { _ in stored = APIKeys.has(provider) }
        if let error { Text(error).repriseFont(.caption).foregroundStyle(.red) }
    }

    static let keysChanged = Notification.Name("RepriseAPIKeysChanged")

    private func save() {
        do {
            try APIKeys.save(draft, for: provider)
            draft = ""; error = nil
            announce()
        } catch let failure { error = failure.localizedDescription }
    }

    private func announce() {
        stored = APIKeys.has(provider)
        NotificationCenter.default.post(name: Self.keysChanged, object: nil)
        changed()
    }
}
