import Foundation

public enum MemoryCalendar {
    public static func dayRange(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return start..<end
    }

    public static func nearest(to date: Date, in moments: [Moment]) -> Moment? {
        moments.min {
            let a = abs($0.timestamp.timeIntervalSince(date))
            let b = abs($1.timestamp.timeIntervalSince(date))
            return a == b ? $0.timestamp < $1.timestamp : a < b
        }
    }
}
