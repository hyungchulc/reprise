import SwiftUI

struct CalendarPopover: View {
    @Binding var date: Date
    let timeZone: TimeZone
    let jump: () -> Void
    var availableDates: [Date] = []

    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @State private var visibleMonth: Date?

    private var calendar: Calendar {
        var calendar = environmentCalendar
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    private var month: Date {
        calendar.dateInterval(of: .month, for: visibleMonth ?? date)?.start ?? date
    }

    private var hours: [RepriseCalendarMath.Hour] {
        RepriseCalendarMath.hours(on: date, calendar: calendar)
    }

    private var selectedHour: RepriseCalendarMath.Hour? {
        hours.first { $0.contains(date) }
    }

    private var recordedDays: Set<Date> {
        Set(availableDates.map { calendar.startOfDay(for: $0) })
    }

    private var recordedHours: Set<Date> {
        Set(availableDates.compactMap { calendar.dateInterval(of: .hour, for: $0)?.start })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.top, 16)
            HStack(alignment: .top, spacing: 0) {
                monthGrid.padding(.trailing, 18)
                Divider().frame(height: 280)
                hourList.padding(.leading, 16)
            }
            .padding(.vertical, 16)
            Divider()
            footer.padding(.top, 14)
        }
        .padding(20)
        .frame(width: 530)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, timeZone)
        .onAppear { visibleMonth = calendar.dateInterval(of: .month, for: date)?.start }
        .onChange(of: date) { _, newDate in
            if !calendar.isDate(newDate, equalTo: month, toGranularity: .month) {
                visibleMonth = calendar.dateInterval(of: .month, for: newDate)?.start
            }
        }
        .onChange(of: timeZone) { _, _ in
            visibleMonth = calendar.dateInterval(of: .month, for: date)?.start
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(formatted(date, template: "EEEE MMMM d"))
                    .repriseFont(.heading)
                    .lineLimit(1)
                Text(timeZone.identifier.replacingOccurrences(of: "_", with: " "))
                    .repriseFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatted(date, template: "jmm"))
                    .repriseFont(.search)
                    .monospacedDigit()
                Text(timeZone.abbreviation(for: date) ?? formatted(date, template: "OOOO"))
                    .repriseFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var monthGrid: some View {
        let recordings = recordedDays
        return VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(formatted(month, template: "MMMM yyyy"))
                    .repriseFont(.heading)
                    .lineLimit(1)
                Spacer(minLength: 4)
                monthButton("chevron.left", label: "Previous month", offset: -1)
                monthButton("chevron.right", label: "Next month", offset: 1)
            }
            .frame(height: 28)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 3), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    let weekday = (calendar.firstWeekday - 1 + index) % 7
                    Text(calendar.veryShortStandaloneWeekdaySymbols[weekday])
                        .repriseFont(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, height: 20)
                        .accessibilityLabel(calendar.standaloneWeekdaySymbols[weekday])
                }
                ForEach(RepriseCalendarMath.days(in: month, calendar: calendar), id: \.self) { day in
                    dayButton(day, recorded: recordings.contains(calendar.startOfDay(for: day)))
                }
            }
        }
        .frame(width: 270)
    }

    private func monthButton(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: offset, to: month) {
                visibleMonth = next
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(CalendarControlStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayButton(_ day: Date, recorded: Bool) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let today = calendar.isDate(day, inSameDayAs: Date())
        return Button {
            date = RepriseCalendarMath.select(day: day, preserving: date, calendar: calendar)
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .repriseFont().fontWeight(selected || today ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(selected ? Color.accentColor : Color.clear, in: Circle())
                    .overlay { Circle().strokeBorder(today && !selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1) }
                Circle()
                    .fill(recorded ? Color.accentColor : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: 36, height: 35)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarControlStyle())
        .accessibilityLabel(formatted(day, template: "EEEE yyyy MMMM d"))
        .accessibilityValue(recorded ? "Memories available" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var hourList: some View {
        let slots = hours
        let recordings = recordedHours
        let repeatedHours = Dictionary(grouping: slots, by: { calendar.component(.hour, from: $0.start) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Time").repriseFont(.heading)
                Spacer(minLength: 4)
                minutePicker
            }
            .frame(height: 28)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(slots) { slot in
                            hourButton(slot, repeated: (repeatedHours[calendar.component(.hour, from: slot.start)]?.count ?? 0) > 1,
                                       recorded: recordings.contains(slot.start))
                            .id(slot.id)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.automatic)
                .frame(height: 240)
                .onAppear {
                    if let selectedHour { proxy.scrollTo(selectedHour.id, anchor: .center) }
                }
                .onChange(of: selectedHour?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var minutePicker: some View {
        Picker("Minute", selection: Binding(
            get: { calendar.component(.minute, from: date) },
            set: { minute in
                if let selectedHour {
                    date = RepriseCalendarMath.select(hour: selectedHour, minute: minute, calendar: calendar)
                }
            }
        )) {
            ForEach(selectedHour.map { RepriseCalendarMath.minutes(in: $0, calendar: calendar) } ?? Array(0..<60), id: \.self) { minute in
                Text(String(format: ":%02d", minute)).tag(minute)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 66)
        .help("Minute")
        .accessibilityLabel("Minute")
    }

    private func hourButton(_ hour: RepriseCalendarMath.Hour, repeated: Bool, recorded: Bool) -> some View {
        let selected = hour.contains(date)
        let label = formatted(hour.start, template: calendar.component(.minute, from: hour.start) == 0 ? "j" : "jmm")
        let offset = formatted(hour.start, template: "OOOO")
        return Button {
            date = RepriseCalendarMath.select(hour: hour, minute: calendar.component(.minute, from: date), calendar: calendar)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).repriseFont().fontWeight(selected ? .semibold : .regular).monospacedDigit()
                    if repeated {
                        Text(offset).repriseFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                } else if recorded {
                    Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: repeated ? 40 : 30)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarControlStyle())
        .accessibilityLabel(repeated ? "\(label), \(offset)" : label)
        .accessibilityValue(recorded ? "Memories available" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                date = Date()
                visibleMonth = calendar.dateInterval(of: .month, for: date)?.start
            } label: {
                Label("Now", systemImage: "clock.arrow.circlepath")
                    .repriseFont()
            }
            .buttonStyle(.borderless)
            Spacer(minLength: 4)
            Button(action: jump) {
                Label("Open Memory", systemImage: "arrow.right")
                    .repriseFont()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func formatted(_ value: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: value)
    }
}

private struct CalendarControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalendarControlLabel(configuration: configuration)
    }

    private struct CalendarControlLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .onHover { hovered = $0 }
        }
    }
}

// Calendar intervals retain distinct instants when a local hour repeats at DST.
enum RepriseCalendarMath {
    struct Hour: Identifiable {
        let start: Date
        let end: Date
        var id: Date { start }
        func contains(_ date: Date) -> Bool { start <= date && date < end }
    }

    static func days(in month: Date, calendar: Calendar) -> [Date] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    static func hours(on day: Date, calendar: Calendar) -> [Hour] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        var result: [Hour] = []
        var cursor = interval.start
        while cursor < interval.end {
            guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
            let end = min(hour.end, interval.end)
            result.append(Hour(start: cursor, end: end))
            cursor = end
        }
        return result
    }

    static func select(day: Date, preserving date: Date, calendar: Calendar) -> Date {
        if calendar.isDate(day, inSameDayAs: date) { return date }
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return day }
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        let result = calendar.nextDate(after: interval.start.addingTimeInterval(-1), matching: time,
                                       matchingPolicy: .nextTimePreservingSmallerComponents,
                                       repeatedTimePolicy: .first, direction: .forward)
        return result.flatMap { interval.start <= $0 && $0 < interval.end ? $0 : nil } ?? interval.start
    }

    static func minutes(in hour: Hour, calendar: Calendar) -> [Int] {
        let first = calendar.component(.minute, from: hour.start)
        return (0..<60).filter { minute in
            let candidate = hour.start.addingTimeInterval(Double(minute - first) * 60)
            return hour.contains(candidate) && calendar.component(.minute, from: candidate) == minute
        }
    }

    static func select(hour: Hour, minute: Int, calendar: Calendar) -> Date {
        let validMinutes = minutes(in: hour, calendar: calendar)
        let selected = validMinutes.min { abs($0 - minute) < abs($1 - minute) } ?? calendar.component(.minute, from: hour.start)
        let delta = selected - calendar.component(.minute, from: hour.start)
        return hour.start.addingTimeInterval(Double(delta) * 60)
    }
}
