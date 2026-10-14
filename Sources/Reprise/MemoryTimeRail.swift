import SwiftUI
import RepriseCore

struct MemoryTimeRail: View {
    @ObservedObject var model: AppModel
    var referenceDate: Date
    var onOpenRecording: (String) -> Void = { _ in }
    @State private var dragOrigin: Date?
    @State private var segments: [TimelineSegment] = []
    @State private var artwork: [String: TimelineArtwork] = [:]
    private let secondsPerPoint = MemoryTimeline.secondsPerPoint

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    let center = size.width / 2
                    let current = referenceDate
                    let axis = model.timelineAxis
                    let currentPosition = axis.position(of: current)
                    let firstTick = floor((currentPosition - Double(center) * secondsPerPoint) / 300) * 300
                    for index in 0..<Int(Double(size.width) * secondsPerPoint / 300 + 2) {
                        let position = firstTick + Double(index) * 300
                        guard position >= 0, position <= axis.extent, let time = axis.date(at: position) else { continue }
                        let x = center + (position - currentPosition) / secondsPerPoint
                        var line = Path(); line.move(to: CGPoint(x: x, y: 70)); line.addLine(to: CGPoint(x: x, y: 73))
                        context.stroke(line, with: .color(.primary.opacity(0.35)), lineWidth: 1)
                        context.draw(Text(time, format: .dateTime.hour().minute())
                            .font(.system(size: model.preferences.textSize - 1, weight: .medium)).foregroundStyle(.primary.opacity(0.85)), at: CGPoint(x: x, y: 84))
                    }
                    var lastIconX: CGFloat = -40
                    for segment in segments where segment.kind != "meeting" {
                        let start = axis.position(of: segment.start)
                        let end = min(axis.extent, axis.position(of: segment.end))
                        let x = center + (start - currentPosition) / secondsPerPoint
                        let width = max(3, (end - start) / secondsPerPoint - 1)
                        guard x + width >= 0 && x < size.width else { continue }
                        let art = artwork["\(segment.bundleID):\(segment.kind)"]
                        let colors = art?.colors.map { Color(nsColor: $0) } ?? [Color.accentColor]
                        let selected = current >= segment.start && current <= segment.end
                        let bar = Path(roundedRect: CGRect(x: x, y: 25, width: width, height: 6), cornerRadius: 3)
                        context.fill(bar, with: .linearGradient(Gradient(colors: colors.map { $0.opacity(selected ? 1 : 0.75) }),
                            startPoint: CGPoint(x: x, y: 28), endPoint: CGPoint(x: x + width, y: 28)))
                        let iconX = min(size.width - 12, max(12, x + width / 2))
                        if let art, iconX - lastIconX >= 28 {
                            context.draw(Image(nsImage: art.icon), in: CGRect(x: iconX - 11, y: 17, width: 22, height: 22))
                            lastIconX = iconX
                        }
                    }
                    for index in axis.gapIndices {
                        let position = (axis.positions[index - 1] + axis.positions[index]) / 2
                        let x = center + (position - currentPosition) / secondsPerPoint
                        guard x >= 0, x <= size.width else { continue }
                        var mark = Path()
                        mark.move(to: CGPoint(x: x - 2, y: 33)); mark.addLine(to: CGPoint(x: x + 2, y: 23))
                        context.stroke(mark, with: .color(.primary.opacity(0.45)), lineWidth: 1)
                    }
                }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    if dragOrigin == nil { dragOrigin = referenceDate }
                    guard let origin = dragOrigin else { return }
                    let offset = -Double(value.translation.width)
                    model.moveTimeline(from: origin, by: offset * secondsPerPoint)
                }.onEnded { _ in dragOrigin = nil })
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    let offset = Double(value.location.x - geometry.size.width / 2) * secondsPerPoint
                    model.moveTimeline(from: referenceDate, by: offset)
                })
                ForEach(segments.filter { $0.kind == "meeting" }) { segment in
                    recordingLane(segment, width: geometry.size.width)
                }
                Rectangle().fill(Color.white.opacity(0.95)).frame(width: 2)
                    .shadow(color: .black.opacity(0.16), radius: 1)
                    .allowsHitTesting(false)
            }.onChange(of: geometry.size.width, initial: true) { _, width in model.setTimelineViewport(width: width) }
        }.frame(height: 96).accessibilityElement(children: .contain).accessibilityLabel("Memory timeline")
            .accessibilityValue("\(model.selection?.appName ?? "") \(referenceDate.formatted(date: .numeric, time: .standard))")
            .accessibilityAdjustableAction { direction in model.step(direction == .increment ? -1 : 1) }
            .task(id: model.timelineAxis.id) { await updateSegments() }
    }

    /// A recording's lane under the timeline. It spans the recording's whole time, and the point
    /// clicked is where playback starts.
    @ViewBuilder
    private func recordingLane(_ segment: TimelineSegment, width: CGFloat) -> some View {
        let start = laneX(segment.start, width: width)
        let end = laneX(segment.end, width: width)
        let left: CGFloat = max(0, start - 14)
        let right: CGFloat = min(width, max(start + 14, end))
        if right > left {
            RecordingLaneLabel(name: segment.appName, width: right - left, open: model.openRecording?.id == segment.id)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in openRecording(segment, atX: left + location.x, width: width) }
                .position(x: (left + right) / 2, y: 53)
                .help(laneHelp(segment))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open timeline recording at \(segment.start.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityAction { openRecording(segment, atX: nil, width: width) }
        }
    }

    private func laneX(_ date: Date, width: CGFloat) -> CGFloat {
        let axis = model.timelineAxis
        let seconds: Double = axis.position(of: date) - axis.position(of: referenceDate)
        return width / 2 + CGFloat(seconds / secondsPerPoint)
    }

    private func openRecording(_ segment: TimelineSegment, atX x: CGFloat?, width: CGFloat) {
        onOpenRecording(segment.id)
        let axis = model.timelineAxis
        let date: Date? = x.flatMap { x in axis.date(at: axis.position(of: referenceDate) + Double(x - width / 2) * secondsPerPoint) }
        Task { await model.openRecording(id: segment.id, at: date) }
    }

    private func laneHelp(_ segment: TimelineSegment) -> String {
        let start = segment.start.formatted(date: .abbreviated, time: .shortened)
        return "Recording: \(start) to \(segment.end.formatted(date: .omitted, time: .shortened))"
    }

    private func updateSegments() async {
        let updated = TimelineSegment.make(from: model.timelineAxis.entries, captureInterval: model.settings.interval)
        segments = updated
        var images: [String: TimelineArtwork] = [:]
        for segment in updated {
            guard !Task.isCancelled else { return }
            let key = "\(segment.bundleID):\(segment.kind)"
            guard images[key] == nil else { continue }
            images[key] = await TimelineArtworkCache.shared.artwork(bundleID: segment.bundleID, kind: segment.kind)
        }
        guard !Task.isCancelled else { return }
        artwork = images
    }
}

/// How a recording's lane looks: a waveform, and its app's name when there is room.
private struct RecordingLaneLabel: View {
    let name: String
    let width: CGFloat
    let open: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold))
            if width > 100 { Text(name).repriseFont(.caption).lineLimit(1) }
        }
        .frame(width: width, height: 22)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(open ? 0.25 : 0.13), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.7), lineWidth: 1) }
    }
}
