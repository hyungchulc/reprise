import AppKit
import SwiftUI
import RepriseCore

struct MemoryAudioPanel: View {
    let moment: Moment
    @ObservedObject var audio: MemoryAudioPlayer
    @ObservedObject var recorder: MeetingRecorder
    @Binding var transcriptExpanded: Bool
    let transcriptHeight: CGFloat
    var summary: MeetingSummary?
    var summarizing = false
    var summaryError: String?
    var providerName = ""
    /// The engine Audio settings choose; the transcribe menu offers the others for one recording.
    var engine = TranscriptionEngine.apple
    var onSummarize: () -> Void = {}
    /// nil transcribes with the chosen engine.
    var onTranscribe: (TranscriptionEngine?) -> Void = { _ in }
    var onRenameSpeaker: (String, String) -> Void = { _, _ in }
    var onDelete: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var contentHeight: CGFloat = 44
    @State private var summaryHeight: CGFloat = 44
    @State private var page: Page = .summary
    private enum Page { case summary, transcript }

    private var segments: [TranscriptSegment] { (moment.transcriptSegments ?? []).filter(\.isValid) }
    private var activeSegment: Int? {
        segments.indices.last { segments[$0].start <= audio.position && audio.position < segments[$0].end }
    }

    var body: some View { content.modifier(GlassSurface()) }

    /// The title row with the recording's actions.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(Color.accentColor)
            Text(moment.windowTitle.isEmpty ? "Meeting" : moment.windowTitle).repriseFont(.heading).lineLimit(1)
            Spacer(minLength: 8)
            if recorder.transcribingMomentID == moment.id {
                ProgressView().controlSize(.small)
                Text(recorder.status).repriseFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                transcribeMenu
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(moment.text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy transcript").accessibilityLabel("Copy transcript").disabled(moment.text.isEmpty)
            Button { transcriptExpanded.toggle() } label: {
                Image(systemName: transcriptExpanded ? "text.bubble.fill" : "text.bubble")
            }.help(transcriptExpanded ? "Hide transcript" : "Show transcript").accessibilityLabel(transcriptExpanded ? "Hide transcript" : "Show transcript")
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }.help("Delete recording").accessibilityLabel("Delete recording")
                    .disabled(recorder.transcribingMomentID == moment.id)
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.help("Close recording").accessibilityLabel("Close recording")
            }
        }
    }

    /// Transcribes with the chosen engine; its menu picks another engine for this recording.
    private var transcribeMenu: some View {
        Menu {
            ForEach(TranscriptionEngine.allCases) { option in
                Button { onTranscribe(option) } label: {
                    if option == engine { Label("Transcribe with \(option.title)", systemImage: "checkmark") } else { Text("Transcribe with \(option.title)") }
                }
            }
        } label: {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
        } primaryAction: { onTranscribe(nil) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(moment.text.isEmpty ? "Transcribe with \(engine.shortTitle); hold for other engines" : "Transcribe again with \(engine.shortTitle); hold for other engines")
            .accessibilityLabel(moment.text.isEmpty ? "Transcribe recording" : "Transcribe again")
            .disabled(recorder.isBusy || recorder.isRecording || !audio.canPlay)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            if transcriptExpanded {
                Picker("View", selection: $page) {
                    Text("Summary").tag(Page.summary)
                    Text("Transcript").tag(Page.transcript)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.bottom, 6)
            }
            if transcriptExpanded && page == .summary {
                ScrollView { summaryContent.background(GeometryReader { proxy in Color.clear.preference(key: SummaryHeightKey.self, value: proxy.size.height) }) }
                    .frame(height: min(transcriptHeight, max(44, summaryHeight))).scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(SummaryHeightKey.self) { height in
                        if abs(height - summaryHeight) > 1 { summaryHeight = height }
                    }
                Divider().padding(.horizontal, 16)
            } else if transcriptExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if !segments.isEmpty {
                                ForEach(segments.indices, id: \.self) { index in
                                    transcriptRow(index).id(index)
                                }
                            } else {
                                Text(recorder.transcribingMomentID == moment.id && !recorder.transcript.isEmpty ? recorder.transcript : (moment.text.isEmpty ? "No transcript was saved for this recording." : moment.text))
                                    .repriseFont().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                            if let note = moment.transcriptionNote, recorder.transcribingMomentID != moment.id {
                                Text(note).repriseFont(.caption).foregroundStyle(.secondary).padding(8)
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 4)
                            .background(GeometryReader { proxy in Color.clear.preference(key: TranscriptHeightKey.self, value: proxy.size.height) })
                    }.frame(height: min(transcriptHeight, max(44, contentHeight))).scrollBounceBehavior(.basedOnSize)
                        .onPreferenceChange(TranscriptHeightKey.self) { height in
                            if abs(height - contentHeight) > 1 { contentHeight = height }
                        }
                        .onChange(of: activeSegment) { _, index in
                            if audio.isPlaying, let index { proxy.scrollTo(index, anchor: .center) }
                        }
                }
                Divider().padding(.horizontal, 16)
            }

            HStack(spacing: 12) {
                Button { audio.seek(to: audio.position - 15) } label: { Image(systemName: "gobackward.15") }.help("Back 15 seconds").accessibilityLabel("Back 15 seconds")
                Button { audio.togglePlayback() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 24)
                }.help(audio.isPlaying ? "Pause audio" : "Play audio").accessibilityLabel(audio.isPlaying ? "Pause audio" : "Play audio")
                Button { audio.seek(to: audio.position + 15) } label: { Image(systemName: "goforward.15") }.help("Forward 15 seconds").accessibilityLabel("Forward 15 seconds")
                Text(Self.timestamp(audio.position)).monospacedDigit().frame(minWidth: 42, alignment: .trailing)
                Slider(value: Binding(get: { audio.position }, set: audio.scrub), in: 0...max(1, audio.duration), onEditingChanged: audio.setScrubbing)
                    .accessibilityLabel("Audio position")
                Text(Self.timestamp(audio.duration)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 42, alignment: .trailing)
            }.repriseFont(.caption).disabled(!audio.canPlay).padding(.horizontal, 16).padding(.vertical, 10)
            if audio.isLoading {
                ProgressView().controlSize(.small).padding(.bottom, 10)
            } else if let error = audio.error {
                Text(error).repriseFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
            }
        }.buttonStyle(.plain)
        .onAppear { page = summary != nil || summarizing || moment.text.isEmpty == false ? .summary : .transcript }
        .onChange(of: moment.id) { _, _ in page = .summary }
        .onChange(of: recorder.transcribingMomentID) { _, id in if id == moment.id { page = .transcript } }
    }

    /// One timed line, with the speaker's name where the speaker changes.
    private func transcriptRow(_ index: Int) -> some View {
        let segment = segments[index]
        let newSpeaker = segment.speaker != nil && (index == 0 || segments[index - 1].speaker != segment.speaker)
        return HStack(alignment: .top, spacing: 12) {
            Button { audio.seek(to: segment.start) } label: {
                Text(Self.timestamp(segment.start)).monospacedDigit().frame(width: 52, alignment: .leading)
            }.foregroundStyle(Color.accentColor).help("Seek to \(Self.timestamp(segment.start))")
                .accessibilityLabel("Seek transcript to \(Self.timestamp(segment.start))").disabled(!audio.canPlay)
            VStack(alignment: .leading, spacing: 4) {
                if newSpeaker, let speaker = segment.speaker {
                    SpeakerChip(name: speaker, color: speakerColor(speaker)) { onRenameSpeaker(speaker, $0) }
                        .disabled(recorder.transcribingMomentID == moment.id)
                }
                Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.repriseFont().padding(8)
            .background(activeSegment == index ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func speakerColor(_ speaker: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
        let index = SpeakerLabels.speakers(in: segments).firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }

    @ViewBuilder private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing with \(providerName)...").foregroundStyle(.secondary)
                }
            } else if let summary {
                Text(summary.overview).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                list("Key points", summary.keyPoints, icon: "circle.fill", size: 5)
                list("Decisions", summary.decisions, icon: "checkmark.seal", size: 11)
                list("Action items", summary.actionItems, icon: "square", size: 11)
                if !summary.matches(moment) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text("The transcript changed after this summary.").foregroundStyle(.secondary)
                        Button("Update", action: onSummarize).buttonStyle(.link)
                    }.repriseFont(.caption)
                }
                HStack(spacing: 12) {
                    Text("\(AIProviderKind(rawValue: summary.provider)?.displayName ?? summary.provider), \(summary.created.formatted(date: .abbreviated, time: .shortened))")
                        .repriseFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.plainText, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.help("Copy summary").accessibilityLabel("Copy summary")
                    Button(action: onSummarize) { Image(systemName: "arrow.clockwise") }.help("Summarize again").accessibilityLabel("Summarize again")
                }
            } else {
                if let summaryError { Text(summaryError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                else if moment.text.isEmpty { Text("Transcribe this recording, then it can be summarized.").foregroundStyle(.secondary) }
                Button(summaryError == nil ? "Summarize with \(providerName)" : "Try Again", systemImage: "sparkles", action: onSummarize)
                    .buttonStyle(.bordered).disabled(moment.text.isEmpty || recorder.transcribingMomentID == moment.id)
            }
        }.repriseFont().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private func list(_ title: String, _ items: [String], icon: String, size: CGFloat) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).repriseFont(.heading)
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon).font(.system(size: size)).foregroundStyle(Color.accentColor)
                        Text(items[index]).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(min(seconds, 359_999))
        if value >= 3_600 { return String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SummaryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A speaker's name above their words. Clicking it renames that speaker everywhere in the recording.
private struct SpeakerChip: View {
    let name: String
    let color: Color
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        Button { draft = name; editing = true } label: {
            Text(name).repriseFont(.caption).fontWeight(.semibold).foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 2).background(color.opacity(0.14), in: Capsule())
        }.buttonStyle(.plain).help("Rename \(name)").accessibilityLabel("Speaker \(name), rename")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rename \(name)").repriseFont(.heading)
                    TextField("Name", text: $draft).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit(commit)
                    Text("Every part this speaker said gets the new name.").repriseFont(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button("Rename", action: commit).keyboardShortcut(.defaultAction).disabled(SpeakerLabels.cleanName(draft) == nil)
                    }
                }.padding(14)
            }
    }

    private func commit() {
        guard let clean = SpeakerLabels.cleanName(draft) else { return }
        editing = false
        if clean != name { rename(clean) }
    }
}
