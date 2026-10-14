import AppKit
import RepriseCore
import SwiftUI

enum IconPlacement: String, Codable, CaseIterable, Identifiable {
    case both, dock, menuBar
    var id: String { rawValue }
    var title: String {
        switch self { case .both: return "Dock & Menu Bar"; case .dock: return "Dock"; case .menuBar: return "Menu Bar" }
    }
}

struct AppPreferences: Codable, Equatable {
    var followSystemAppearance = true
    var darkMode = false
    var followSystemAccent = true
    var accentRed = 0.0
    var accentGreen = 0.55
    var accentBlue = 0.55
    var textSize = 13.0
    var animateSearch = true
    var iconPlacement = IconPlacement.both
    var showOnLaunch = true
    var startRecordingOnLaunch = false
    var detectMeetings = false
    var includeSystemAudio = true
    var transcribeMeetings = true
    /// Meetings are transcribed in each of these languages; the first is also saved for earlier versions.
    var speechLocales = SpeechLanguageSelection.defaults() { didSet { speechLocale = speechLocales.first ?? speechLocale } }
    var speechLocale = Locale.current.identifier
    var pauseReminders: Bool? = true
    var edgeGlow: Bool? = true
    /// After transcription, the chosen AI provider summarizes each meeting and a notification says when it is ready.
    var summarizeMeetings = true

    init() {}

    // Each key falls back on its own, so a setting added in a later version never resets the others.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        followSystemAppearance = values.value(.followSystemAppearance, default: defaults.followSystemAppearance)
        darkMode = values.value(.darkMode, default: defaults.darkMode)
        followSystemAccent = values.value(.followSystemAccent, default: defaults.followSystemAccent)
        accentRed = values.value(.accentRed, default: defaults.accentRed)
        accentGreen = values.value(.accentGreen, default: defaults.accentGreen)
        accentBlue = values.value(.accentBlue, default: defaults.accentBlue)
        textSize = values.value(.textSize, default: defaults.textSize)
        animateSearch = values.value(.animateSearch, default: defaults.animateSearch)
        iconPlacement = values.value(.iconPlacement, default: defaults.iconPlacement)
        showOnLaunch = values.value(.showOnLaunch, default: defaults.showOnLaunch)
        startRecordingOnLaunch = values.value(.startRecordingOnLaunch, default: defaults.startRecordingOnLaunch)
        detectMeetings = values.value(.detectMeetings, default: defaults.detectMeetings)
        includeSystemAudio = values.value(.includeSystemAudio, default: defaults.includeSystemAudio)
        transcribeMeetings = values.value(.transcribeMeetings, default: defaults.transcribeMeetings)
        speechLocale = values.value(.speechLocale, default: defaults.speechLocale)
        // One saved language from an earlier version stays first, joined by this Mac's languages.
        let migrated = values.contains(.speechLocale)
            ? SpeechLanguageSelection.unique([speechLocale] + defaults.speechLocales, byLanguage: true, limit: 3) : defaults.speechLocales
        speechLocales = values.value(.speechLocales, default: migrated)
        pauseReminders = values.value(.pauseReminders, default: true)
        edgeGlow = values.value(.edgeGlow, default: true)
        summarizeMeetings = values.value(.summarizeMeetings, default: defaults.summarizeMeetings)
    }

    var colorScheme: ColorScheme? { followSystemAppearance ? nil : (darkMode ? .dark : .light) }
    var accent: Color { followSystemAccent ? Color(nsColor: .controlAccentColor) : Color(red: accentRed, green: accentGreen, blue: accentBlue) }
    mutating func setAccent(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        accentRed = rgb.redComponent; accentGreen = rgb.greenComponent; accentBlue = rgb.blueComponent
    }
}

private struct RepriseTextSizeKey: EnvironmentKey { static let defaultValue = 13.0 }
extension EnvironmentValues {
    var repriseTextSize: Double {
        get { self[RepriseTextSizeKey.self] }
        set { self[RepriseTextSizeKey.self] = newValue }
    }
}

enum RepriseTextStyle { case caption, body, heading, title, search }
private struct RepriseFont: ViewModifier {
    @Environment(\.repriseTextSize) private var size
    let style: RepriseTextStyle
    func body(content: Content) -> some View {
        let offset: Double = switch style { case .caption: -1; case .body, .heading: 0; case .search: 3; case .title: 7 }
        content.font(.system(size: size + offset, weight: style == .heading || style == .title ? .semibold : .regular))
    }
}
extension View {
    func repriseFont(_ style: RepriseTextStyle = .body) -> some View { modifier(RepriseFont(style: style)) }
    func repriseAppearance(_ preferences: AppPreferences) -> some View {
        self.preferredColorScheme(preferences.colorScheme)
            .tint(preferences.accent).accentColor(preferences.accent)
            .environment(\.repriseTextSize, preferences.textSize)
            .font(.system(size: preferences.textSize))
    }
}

struct RepriseIcon: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    var size: CGFloat = 64
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else { Image(systemName: "clock.arrow.circlepath").font(.system(size: size * 0.6)).frame(width: size, height: size) }
    }
}
