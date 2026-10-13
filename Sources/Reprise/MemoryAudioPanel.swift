import AppKit
import SwiftUI
import RepriseCore

struct MemoryAudioPanel: View {
    let moment: Moment
    @ObservedObject var audio: MemoryAudioPlayer
    @ObservedObject var recorder: MeetingRecorder
    @Binding var transcriptExpanded: Bool
    let transcriptHeight: CGFloat
    var framed = true
    var onTranscribe: () -> Void = {}
    var onClose: (() -> Void)?
    @State private var contentHeight: CGFloat = 44

    private var segments: [TranscriptSegment] { (moment.transcriptSegments ?? []).filter(\.isValid) }
    private var activeSegment: Int? {
        segments.indices.last { segments[$0].start <= audio.position && audio.position < segments[$0].end }
    }

    var body: some View {
        Group {
            if framed { content.modifier(GlassSurface()) }
            else { content }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                Text(moment.windowTitle.isEmpty ? "Meeting" : moment.windowTitle).repriseFont(.heading).lineLimit(1)
                Spacer(minLength: 8)
                if recorder.transcribingMomentID == moment.id {
                    ProgressView().controlSize(.small)
                    Text(recorder.status).repriseFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button(action: onTranscribe) { Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90") }
                        .help(moment.text.isEmpty ? "Transcribe recording" : "Transcribe again")
                        .accessibilityLabel(moment.text.isEmpty ? "Transcribe recording" : "Transcribe again")
                        .disabled(recorder.isBusy || recorder.isRecording || !audio.canPlay)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(moment.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy transcript").accessibilityLabel("Copy transcript").disabled(moment.text.isEmpty)
                Button { transcriptExpanded.toggle() } label: {
                    Image(systemName: transcriptExpanded ? "text.bubble.fill" : "text.bubble")
                }.help(transcriptExpanded ? "Hide transcript" : "Show transcript").accessibilityLabel(transcriptExpanded ? "Hide transcript" : "Show transcript")
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }.help("Close recording").accessibilityLabel("Close recording")
                }
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            if transcriptExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if !segments.isEmpty {
                                ForEach(segments.indices, id: \.self) { index in
                                    let segment = segments[index]
                                    HStack(alignment: .top, spacing: 12) {
                                        Button { audio.seek(to: segment.start) } label: {
                                            Text(Self.timestamp(segment.start)).monospacedDigit().frame(width: 52, alignment: .leading)
                                        }.foregroundStyle(Color.accentColor).help("Seek to \(Self.timestamp(segment.start))")
                                            .accessibilityLabel("Seek transcript to \(Self.timestamp(segment.start))").disabled(!audio.canPlay)
                                        Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.repriseFont().padding(8)
                                        .background(activeSegment == index ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .id(index)
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
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(min(seconds, 359_999))
        if value >= 3_600 { return String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
