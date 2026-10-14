import AppKit
import Combine
import RepriseCore
import SwiftUI

/// The meeting assistant's small window beside the meeting. It floats over other apps without
/// taking focus from them, except while something is typed into it.
@MainActor
final class AssistantPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()
        model.assistant.$isRunning.removeDuplicates().sink { [weak self] running in
            if running { self?.show() } else { self?.panel?.orderOut(nil) }
        }.store(in: &subscriptions)
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Meeting Assistant"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 300, height: 360)
            panel.delegate = self
            let model = model
            panel.contentView = NSHostingView(rootView: AssistantView(model: model, assistant: model.assistant))
            if !panel.setFrameUsingName("RepriseMeetingAssistant") {
                let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - 380 - 16, y: visible.maxY - 560 - 16))
            }
            panel.setFrameAutosaveName("RepriseMeetingAssistant")
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    /// Closing the window stops listening.
    func windowWillClose(_ notification: Notification) {
        if model.assistant.isRunning { model.assistant.stop() }
    }
}

struct AssistantView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        VStack(spacing: 0) {
            AssistantStatus(assistant: assistant)
                .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 8)
            Divider()
            // Answers matter most, so they get the larger share.
            GeometryReader { space in
                VStack(spacing: 0) {
                    AssistantTranscript(lines: assistant.lines).frame(height: space.size.height * 0.4)
                    Divider()
                    AssistantAnswers(answers: assistant.answers) { moment in Task { await model.openMemory(id: moment.id) } }
                }
            }
            Divider()
            AssistantAskBar(model: model, assistant: assistant)
                .padding(12)
        }
        .repriseAppearance(model.preferences)
    }
}

private struct AssistantStatus: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(assistant.heardBy.isEmpty ? Color.secondary : Color.red).frame(width: 8, height: 8)
                Text(listening).font(.callout.weight(.medium))
                Spacer()
            }
            if let problem = assistant.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(3)
            } else if let notice = assistant.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var listening: String {
        guard !assistant.heardBy.isEmpty else { return "Starting..." }
        let you = assistant.heardBy[.you].map { "You with \($0)" }
        let them = assistant.heardBy[.them].map { "Them with \($0)" }
        return "Listening: " + [you, them].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct AssistantTranscript: View {
    let lines: [MeetingAssistant.Line]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text("What you and the others say shows here.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(lines.suffix(120)) { line in AssistantLineRow(line: line).id(line.id) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .onChange(of: lines.last?.text) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct AssistantLineRow: View {
    let line: MeetingAssistant.Line
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.speaker == .you ? "You" : "Them").font(.caption.weight(.semibold))
                .foregroundStyle(line.speaker == .you ? Color.accentColor : Color.secondary).frame(width: 36, alignment: .leading)
            Text(line.text).font(.callout).foregroundStyle(line.final ? Color.primary : Color.secondary).textSelection(.enabled)
        }
    }
}

private struct AssistantAnswers: View {
    let answers: [MeetingAssistant.Answer]
    let open: (Moment) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if answers.isEmpty {
                        Text("Answers show here when the others ask a question, or when you ask one below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(answers.suffix(3)) { answer in AssistantAnswerCard(answer: answer, open: open).id(answer.id) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .onChange(of: answers.last?.text) { _, _ in
                if let last = answers.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct AssistantAnswerCard: View {
    let answer: MeetingAssistant.Answer
    let open: (Moment) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(answer.automatic ? "Asked" : "You asked"): \(answer.question)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if !answer.text.isEmpty {
                Text(answer.text).font(.body).textSelection(.enabled)
            }
            state
            if !answer.sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(answer.sources, id: \.label) { source in
                        Button { open(source.moment) } label: {
                            Text("\(source.label) · \(source.moment.appName) · \(source.moment.timestamp.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(.caption).lineLimit(1)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help(source.moment.windowTitle)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var state: some View {
        switch answer.state {
        case .thinking: Label("Thinking...", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
        case .searching(let terms): Label("Searching memories for \(terms)...", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .answering, .done: EmptyView()
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(4)
        }
    }
}

private struct AssistantAskBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask anything...", text: $assistant.draft).textFieldStyle(.roundedBorder).onSubmit { assistant.askDraft() }
                Button { assistant.askDraft() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless).disabled(assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty).help("Ask")
            }
            HStack {
                Button("Answer Last Question", systemImage: "questionmark.bubble") { assistant.answerLast() }
                    .disabled(!assistant.lines.contains { $0.speaker == .them })
                Spacer()
                Toggle("Auto", isOn: $model.preferences.assistant.autoAnswer).toggleStyle(.switch).controlSize(.mini)
                    .help("Answer the others' questions as they ask them")
            }.font(.caption)
        }
    }
}
