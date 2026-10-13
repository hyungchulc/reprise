import Foundation

public enum MemoryTimeline {
    public static let secondsPerPoint: Double = 4
    public static let gapThreshold: TimeInterval = 300
    public static let gapWidth: TimeInterval = 32

    public static func displayDuration(_ interval: TimeInterval) -> TimeInterval {
        interval > gapThreshold ? gapWidth : max(0, interval)
    }

    public static func scrollOffset(x: Double, y: Double, precise: Bool) -> TimeInterval {
        // Native deltas already reflect the user's scrolling preference. Down goes back;
        // horizontal input moves the strip, with older memories on its left.
        let delta = abs(x) > abs(y) ? -x : y
        return delta * secondsPerPoint * (precise ? 1 : 10)
    }

    public static func clamp(_ date: Date, oldest: Date?, newest: Date?) -> Date {
        var result = date
        if let oldest { result = max(oldest, result) }
        if let newest { result = min(newest, result) }
        return result
    }
}

public struct TimelineEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let appName: String
    public let bundleID: String
    public let kind: String
    public let audioDuration: TimeInterval?

    public init(id: String, timestamp: Date, appName: String, bundleID: String, kind: String, audioDuration: TimeInterval? = nil) {
        self.id = id; self.timestamp = timestamp; self.appName = appName
        self.bundleID = bundleID; self.kind = kind
        self.audioDuration = audioDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public init(_ moment: Moment) {
        self.init(id: moment.id, timestamp: moment.timestamp, appName: moment.appName,
                  bundleID: moment.bundleID, kind: moment.kind, audioDuration: moment.audioDuration)
    }
}

/// Display coordinates contain recorded time and short separators, never hours of empty time.
public struct MemoryTimelineAxis: Sendable {
    public let id = UUID()
    public let entries: [TimelineEntry]
    public let positions: [TimeInterval]
    public let gapIndices: [Int]
    public var extent: TimeInterval { positions.last ?? 0 }

    public init(entries: [TimelineEntry]) {
        self.entries = entries.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var positions: [TimeInterval] = [], gaps: [Int] = []
        for index in self.entries.indices {
            let elapsed = index == 0 ? 0 : self.entries[index].timestamp.timeIntervalSince(self.entries[index - 1].timestamp)
            positions.append((positions.last ?? 0) + MemoryTimeline.displayDuration(elapsed))
            if elapsed > MemoryTimeline.gapThreshold { gaps.append(index) }
        }
        self.positions = positions; self.gapIndices = gaps
    }

    public func position(of date: Date) -> TimeInterval {
        guard let first = entries.first, let last = entries.last else { return 0 }
        if date <= first.timestamp { return date.timeIntervalSince(first.timestamp) }
        if date >= last.timestamp { return extent + date.timeIntervalSince(last.timestamp) }
        let next = upperBound { entries[$0].timestamp <= date }
        let previous = next - 1
        let duration = entries[next].timestamp.timeIntervalSince(entries[previous].timestamp)
        let fraction = date.timeIntervalSince(entries[previous].timestamp) / duration
        return positions[previous] + fraction * (positions[next] - positions[previous])
    }

    public func date(at position: TimeInterval, direction: Double = 0) -> Date? {
        guard let first = entries.first, let last = entries.last else { return nil }
        if position <= 0 { return first.timestamp.addingTimeInterval(position) }
        if position >= extent { return last.timestamp.addingTimeInterval(position - extent) }
        let next = upperBound { positions[$0] < position }
        if positions[next] == position { return entries[next].timestamp }
        let previous = next - 1
        let duration = entries[next].timestamp.timeIntervalSince(entries[previous].timestamp)
        let fraction = (position - positions[previous]) / (positions[next] - positions[previous])
        if duration > MemoryTimeline.gapThreshold {
            return direction < 0 || (direction == 0 && fraction < 0.5) ? entries[previous].timestamp : entries[next].timestamp
        }
        return entries[previous].timestamp.addingTimeInterval(duration * fraction)
    }

    public func moving(from date: Date, by offset: TimeInterval) -> Date {
        guard offset != 0 else { return date }
        return self.date(at: position(of: date) + offset, direction: offset) ?? date.addingTimeInterval(offset)
    }

    private func upperBound(_ isBefore: (Int) -> Bool) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return min(low, entries.count - 1)
    }
}
