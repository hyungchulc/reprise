import Foundation

/// Time words typed into the quick search, read on this Mac: 오늘, 어제 저녁, 지난주, 10월 13일,
/// "last week". The live search then shows that time instead of looking for the words in screen
/// text, and any other words still search the text inside it.
public struct QuickSearchTime: Equatable, Sendable {
    public let interval: DateInterval
    public let label: String
    /// The words left for the text search.
    public let text: String

    private static let particles = ["에서는", "에서", "부터", "까지", "에는", "에도", "이랑", "에", "의", "은", "는", "도", "랑", "꺼", "거", "것"]
    private static let levels: [String: (from: Int, to: Int, label: String)] = [
        "새벽": (0, 6, "early morning"), "아침": (6, 11, "morning"), "오전": (0, 12, "morning"), "점심": (11, 14, "lunch"),
        "오후": (12, 18, "afternoon"), "저녁": (17, 22, "evening"), "밤": (20, 28, "night"),
        "morning": (6, 12, "morning"), "lunch": (11, 14, "lunch"), "afternoon": (12, 18, "afternoon"),
        "evening": (17, 22, "evening"), "night": (20, 28, "night")
    ]
    private static let weekdays: [String: Int] = [
        "일요일": 1, "월요일": 2, "화요일": 3, "수요일": 4, "목요일": 5, "금요일": 6, "토요일": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7
    ]

    private enum Span { case day(Int), week(Int), month(Int), date(Date), weekday(Int) }

    /// Parts of the day (저녁, morning) count only beside a day word, since they are also everyday
    /// words to search for.
    public static func parse(_ query: String, now: Date = Date(), calendar given: Calendar) -> QuickSearchTime? {
        // Dates are Gregorian whatever calendar the Mac shows; the week start and zone stay its own.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = given.timeZone; calendar.firstWeekday = given.firstWeekday; calendar.locale = given.locale
        let tokens = query.split(whereSeparator: \.isWhitespace).map { String($0) }
        guard !tokens.isEmpty, tokens.count <= 12 else { return nil }
        let words = tokens.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var used = Array(repeating: false, count: tokens.count)
        var span: Span?
        var hours: (from: Int, to: Int, label: String)?

        func stems(_ word: String) -> [String] {
            [word] + particles.compactMap { word.hasSuffix($0) && word.count > $0.count ? String(word.dropLast($0.count)) : nil }
        }
        func number(_ word: String, suffix: String) -> Int? {
            guard word.hasSuffix(suffix) else { return nil }
            return Int(word.dropLast(suffix.count))
        }
        func date(month: Int, day: Int, year: Int? = nil) -> Date? {
            let thisYear = calendar.component(.year, from: now)
            guard let candidate = calendar.date(from: DateComponents(year: year ?? thisYear, month: month, day: day)),
                  calendar.component(.day, from: candidate) == day else { return nil }
            // Without a year, a date later than today means last year's.
            if year == nil, candidate > now { return calendar.date(byAdding: .year, value: -1, to: candidate) }
            return candidate
        }
        func single(_ word: String) -> (Span?, (from: Int, to: Int, label: String)?)? {
            switch word {
            case "오늘", "금일", "today": return (.day(0), nil)
            case "어제", "어저께", "yesterday": return (.day(-1), nil)
            case "그제", "그저께", "엊그제": return (.day(-2), nil)
            case "어젯밤", "간밤": return (.day(-1), levels["밤"])
            case "오늘밤", "tonight": return (.day(0), levels["밤"])
            case "이번주", "금주": return (.week(0), nil)
            case "지난주", "저번주": return (.week(-1), nil)
            case "이번달": return (.month(0), nil)
            case "지난달", "저번달": return (.month(-1), nil)
            default: break
            }
            if let weekday = weekdays[word] { return (.weekday(weekday), nil) }
            if let level = levels[word] { return (nil, level) }
            if let days = number(word, suffix: "일전"), (0...366).contains(days) { return (.day(-days), nil) }
            let parts = word.components(separatedBy: CharacterSet(charactersIn: "-/"))
            if parts.count == 3, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
               let value = date(month: month, day: day, year: year) { return (.date(value), nil) }
            if parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]), let value = date(month: month, day: day) {
                return (.date(value), nil)
            }
            if word.hasSuffix("일"), let split = word.range(of: "월"), let month = Int(word[..<split.lowerBound]),
               let day = Int(word[split.upperBound...].dropLast()), let value = date(month: month, day: day) { return (.date(value), nil) }
            return nil
        }

        var index = 0
        while index < words.count {
            let candidates = stems(words[index])
            let next = index + 1 < words.count ? stems(words[index + 1]) : []
            let third = index + 2 < words.count ? words[index + 2] : nil
            var consumed = 0
            if span == nil {
                if ["이번", "this"].contains(words[index]), next.contains(where: { ["주", "week"].contains($0) }) { span = .week(0); consumed = 2 }
                else if ["지난", "저번", "last"].contains(words[index]), next.contains(where: { ["주", "week"].contains($0) }) { span = .week(-1); consumed = 2 }
                else if ["이번", "this"].contains(words[index]), next.contains(where: { ["달", "month"].contains($0) }) { span = .month(0); consumed = 2 }
                else if ["지난", "저번", "last"].contains(words[index]), next.contains(where: { ["달", "month"].contains($0) }) { span = .month(-1); consumed = 2 }
                else if let days = number(words[index], suffix: "일"), next.contains("전"), (0...366).contains(days) { span = .day(-days); consumed = 2 }
                else if let days = Int(words[index]), ["day", "days"].contains(next.first ?? ""), third == "ago", (0...366).contains(days) { span = .day(-days); consumed = 3 }
                else if let month = number(words[index], suffix: "월"), let day = next.lazy.compactMap({ number($0, suffix: "일") }).first,
                        let value = date(month: month, day: day) { span = .date(value); consumed = 2 }
                else if words[index] == "day", next.first == "before", third == "yesterday" { span = .day(-2); consumed = 3 }
            }
            if consumed == 0, let match = candidates.lazy.compactMap(single).first, span == nil || match.0 == nil, hours == nil || match.1 == nil {
                if let found = match.0 { span = found }
                if let found = match.1 { hours = found }
                consumed = 1
            }
            if consumed > 0 {
                for offset in 0..<consumed { used[index + offset] = true }
                index += consumed
            } else {
                index += 1
            }
        }
        guard let span else { return nil }

        let today = calendar.startOfDay(for: now)
        func dayInterval(_ start: Date) -> DateInterval {
            DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        }
        var interval: DateInterval
        var label: String
        var singleDay = true
        switch span {
        case .day(let offset):
            interval = dayInterval(calendar.date(byAdding: .day, value: offset, to: today) ?? today)
            label = switch offset { case 0: "Today"; case -1: "Yesterday"; default: "\(-offset) days ago" }
        case .week(let offset):
            let base = calendar.date(byAdding: .weekOfYear, value: offset, to: now) ?? now
            interval = calendar.dateInterval(of: .weekOfYear, for: base) ?? dayInterval(today)
            label = offset == 0 ? "This week" : "Last week"; singleDay = false
        case .month(let offset):
            let base = calendar.date(byAdding: .month, value: offset, to: now) ?? now
            interval = calendar.dateInterval(of: .month, for: base) ?? dayInterval(today)
            label = offset == 0 ? "This month" : "Last month"; singleDay = false
        case .date(let value):
            interval = dayInterval(calendar.startOfDay(for: value))
            label = value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar, timeZone: calendar.timeZone))
        case .weekday(let weekday):
            // The latest such day, today included.
            let back = (calendar.component(.weekday, from: now) - weekday + 7) % 7
            interval = dayInterval(calendar.date(byAdding: .day, value: -back, to: today) ?? today)
            label = calendar.weekdaySymbols[weekday - 1]
        }
        if let hours, singleDay,
           let start = calendar.date(byAdding: .hour, value: hours.from, to: interval.start),
           let end = calendar.date(byAdding: .hour, value: hours.to, to: interval.start) {
            interval = DateInterval(start: start, end: end)
            label += " " + hours.label
        }
        let rest = tokens.indices.filter { !used[$0] }.map { tokens[$0] }.joined(separator: " ")
        return QuickSearchTime(interval: interval, label: label, text: rest)
    }
}
