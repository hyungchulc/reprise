import RepriseCore
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
