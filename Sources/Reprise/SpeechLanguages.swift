import Foundation
import Speech
import RepriseCore

/// Keeps an on-device recognizer installed for each chosen meeting language. On macOS 26 and
/// later, SpeechAnalyzer models download through AssetInventory as soon as a language is chosen.
@MainActor
final class SpeechLanguages: ObservableObject {
    enum State: Equatable {
        case checking, installed, downloading(Double), needsDownload, unavailable, failed(String)
    }
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var options: [Option] = []
    @Published private(set) var states: [String: State] = [:]
    private var catalog: [String: Locale] = [:]
    private var loaded = false
    private var installs: [String: Task<Void, Never>] = [:]

    /// SpeechAnalyzer hears every chosen language in one pass and needs no Speech Recognition permission.
    static var usesSpeechAnalyzer: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    func name(for id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    /// Maps saved choices onto the recognizer catalog, e.g. ko-US to ko-KR, keeping unknown ones visible.
    func normalize(_ selection: [String]) async -> [String] {
        await loadCatalog()
        guard !catalog.isEmpty else { return selection }
        let supported = Array(catalog.keys)
        return SpeechLanguageSelection.unique(selection.map { SpeechLanguageSelection.resolve($0, supported: supported) ?? $0 })
    }

    /// Installs what the selection needs and releases languages that were removed.
    func sync(_ selection: [String]) async {
        await loadCatalog()
        if #available(macOS 26, *), Self.usesSpeechAnalyzer {
            for locale in await AssetInventory.reservedLocales where !selection.contains(locale.identifier(.bcp47)) {
                await AssetInventory.release(reservedLocale: locale)
            }
        }
        for id in selection { await refresh(id) }
        for id in selection where states[id] == .needsDownload || states.isFailed(id) { await install(id) }
    }

    /// Recognizer locales ready now, downloading missing models first, plus notes for the rest.
    func prepare(_ selection: [String]) async -> (locales: [Locale], notes: [String]) {
        await loadCatalog()
        var locales: [Locale] = [], notes: [String] = []
        for id in SpeechLanguageSelection.unique(selection) {
            await refresh(id)
            if states[id] == .needsDownload || states.isFailed(id) { await install(id) }
            else if case .downloading = states[id] { await install(id) }
            switch states[id] {
            case .installed: if let locale = catalog[id] { locales.append(locale) }
            case .failed(let message): notes.append("\(name(for: id)) could not be prepared: \(message)")
            case .needsDownload where !Self.usesSpeechAnalyzer:
                notes.append("\(name(for: id)) needs its on-device model. Add it in System Settings > Keyboard > Dictation.")
            default: notes.append("On-device transcription is unavailable for \(name(for: id)).")
            }
        }
        return (locales, notes)
    }

    private func loadCatalog() async {
        guard !loaded else { return }
        var locales: [Locale]
        if #available(macOS 26, *), Self.usesSpeechAnalyzer { locales = await SpeechTranscriber.supportedLocales }
        else { locales = Array(SFSpeechRecognizer.supportedLocales()) }
        for locale in locales { catalog[locale.identifier(.bcp47)] = locale }
        options = catalog.keys.map { Option(id: $0, name: name(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loaded = !catalog.isEmpty
    }

    private func refresh(_ id: String) async {
        guard let locale = catalog[id] else { states[id] = .unavailable; return }
        if #available(macOS 26, *), Self.usesSpeechAnalyzer {
            if installs[id] != nil { return }
            switch await AssetInventory.status(forModules: [Self.transcriber(locale)]) {
            case .installed: states[id] = .installed
            case .downloading: if case .downloading = states[id] {} else { states[id] = .downloading(0) }
            case .supported: states[id] = .needsDownload
            case .unsupported: states[id] = .unavailable
            @unknown default: states[id] = .unavailable
            }
        } else {
            let recognizer = SFSpeechRecognizer(locale: locale)
            states[id] = recognizer?.supportsOnDeviceRecognition == true ? .installed : (recognizer == nil ? .unavailable : .needsDownload)
        }
    }

    /// One download per language; callers that need it wait for the same task.
    private func install(_ id: String) async {
        guard #available(macOS 26, *), Self.usesSpeechAnalyzer, let locale = catalog[id] else { return }
        if let running = installs[id] { await running.value; return }
        let task = Task { [weak self] in
            do {
                try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.transcriber(locale)]) {
                    self?.states[id] = .downloading(0)
                    let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in if case .downloading = self?.states[id] { self?.states[id] = .downloading(fraction) } }
                    }
                    defer { observation.invalidate() }
                    try await request.downloadAndInstall()
                }
                self?.states[id] = .installed
            } catch {
                self?.states[id] = .failed(error.localizedDescription)
            }
        }
        installs[id] = task
        await task.value
        installs[id] = nil
    }

    @available(macOS 26, *)
    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
}

private extension Dictionary where Key == String, Value == SpeechLanguages.State {
    func isFailed(_ id: String) -> Bool { if case .failed = self[id] { return true }; return false }
}
