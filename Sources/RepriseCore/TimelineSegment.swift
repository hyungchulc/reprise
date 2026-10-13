import Foundation

public struct TimelineSegment: Identifiable, Sendable {
    public let id: String
    public let start: Date
    public var end: Date
    public let appName: String
    public let bundleID: String
    public let kind: String

    public static func make(from moments: [Moment], captureInterval: Double) -> [TimelineSegment] {
        make(from: moments.map(TimelineEntry.init), captureInterval: captureInterval)
    }

    public static func make(from entries: [TimelineEntry], captureInterval: Double) -> [TimelineSegment] {
        let ordered = entries.filter { $0.kind != "meeting" }.sorted { $0.timestamp < $1.timestamp }
        var segments: [TimelineSegment] = []
        let tail = max(3, min(60, captureInterval))
        for (index, moment) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].timestamp : moment.timestamp.addingTimeInterval(tail)
            let end = next.timeIntervalSince(moment.timestamp) > MemoryTimeline.gapThreshold ? moment.timestamp.addingTimeInterval(tail) : next
            if let last = segments.last, last.bundleID == moment.bundleID, last.appName == moment.appName,
               last.kind == moment.kind, last.end >= moment.timestamp {
                segments[segments.count - 1].end = max(last.end, end)
            } else {
                segments.append(TimelineSegment(id: moment.id, start: moment.timestamp, end: end,
                    appName: moment.appName, bundleID: moment.bundleID, kind: moment.kind))
            }
        }
        // Recordings overlap screen activity and retain their duration, never merge into an app run.
        segments += entries.filter { $0.kind == "meeting" }.map { entry in
            TimelineSegment(id: entry.id, start: entry.timestamp,
                end: entry.timestamp.addingTimeInterval(entry.audioDuration ?? tail),
                appName: entry.appName, bundleID: entry.bundleID, kind: entry.kind)
        }
        return segments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
