import SwiftUI

extension View {
    /// The whole cell around an icon takes the click. A plain button otherwise answers only on the
    /// icon's own shape, a few points across, and clicks beside it on the bar do nothing.
    func controlCell(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height).contentShape(Rectangle())
    }
}

struct RecordingControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureEngine
    @ObservedObject var meeting: MeetingRecorder
    var body: some View {
        Button { Task { await model.toggleRecording() } } label: {
            Image(systemName: capture.isRecording ? "pause.circle.fill" : "record.circle")
                .foregroundStyle(capture.isRecording ? Color.red : Color.primary).controlCell(width: 30, height: 36)
        }.help(capture.isRecording ? "Pause screen recording" : "Start screen recording")
        Button { Task { await model.toggleMeeting() } } label: {
            Group {
                if meeting.isBusy { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Image(systemName: meeting.isRecording ? "stop.circle.fill" : "mic").foregroundStyle(meeting.isRecording ? Color.red : Color.primary) }
            }.controlCell(width: 30, height: 36)
        }.disabled(meeting.isBusy).help(meeting.isRecording ? meeting.status + ". Stop recording" : "Record microphone and system audio")
        if meeting.isRecording || meeting.isBusy {
            Text(meeting.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 230).padding(.horizontal, 4)
        }
    }
}

struct GlassSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
    }
}

struct RoundGlassSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular.interactive(), in: Circle()) }
        else { content.background(.regularMaterial, in: Circle()) }
    }
}

struct CapsuleGlassSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}
