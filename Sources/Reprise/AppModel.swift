import AppKit
import AVFoundation
import Combine
import ImageIO
import LocalAuthentication
import RepriseCore
import Speech
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import Vision

@MainActor
final class AppModel: ObservableObject {
    let root: URL
    let store: MomentStore
    /// This library's keys; MCP consent is signed with them.
    let keys: VaultKeys
    var cipher: VaultCipher { store.cipher }
    let capture: CaptureEngine
    let meeting: MeetingRecorder
    let ai = AIClient()
    let permissions = PermissionCenter()
    let meetingDetector = MeetingDetector()
    let updater = AppUpdater()
    let shortcut = GlobalShortcut()
    let speechLanguages = SpeechLanguages()
    let archiver: FrameArchiver
    /// Set while screen recording runs; still set at launch means the last run ended without
    /// Pause or Quit, such as a crash, force quit or power loss, so recording resumes.
    static let captureSessionKey = "captureSessionOpen"
    @Published var moments: [Moment] = []
    @Published var matchingMoments: [Moment] = []
    @Published var aiMatches: [Moment]?
    @Published var searchError: String?
    @Published var searchNotice: String?
    @Published private(set) var restoredSearchDate: Date?
    @Published var searchPresented = false
    @Published private(set) var searchTurns: [MemorySearchTurn] = []
    @Published private(set) var pendingQuestion: String?
    @Published var selection: Moment?
    @Published private(set) var timelineDate: Date?
    @Published private(set) var timelineAxis = MemoryTimelineAxis(entries: [])
    @Published var stats = LibraryStats()
    @Published var usages: [UsageEntry] = []
    @Published var search = ""
    @Published private(set) var searchHistory = SearchHistory()
    @Published var appFilter: String?
    @Published var mode = "all"
    @Published var dayFilter: Date?
    @Published var error: String?
    @Published var busy = false
    @Published var hasMore = false
    @Published var showInspector = false
    @Published var showSettings = false
    var settingsPage = "General"
    @Published var question = ""
    @Published var response: AIResponse?
    @Published var asking = false
    @Published var providerStatus: AIProviderStatus?
    @Published var accountStatus: AIAccountStatus?
    @Published var checkingProvider = false
    @Published var availableModels: [AIModelOption] = []
    /// A model download in Ollama: name, completed fraction when known, and Ollama's status line.
    @Published private(set) var modelDownload: (name: String, fraction: Double?, status: String)?
    @Published private(set) var summaries: [String: MeetingSummary] = [:]
    @Published private(set) var summarizing: Set<String> = []
    @Published private(set) var summaryErrors: [String: String] = [:]
    private var watchedTranscription: String?
    @Published var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
    @Published var preferences: AppPreferences {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(preferences), forKey: "appPreferences")
            applyPreferences()
            // A newly chosen language downloads its speech model right away, not at the next meeting.
            if preferences.transcribeMeetings, preferences.speechLocales != oldValue.speechLocales || !oldValue.transcribeMeetings {
                let selection = preferences.speechLocales
                Task { await speechLanguages.sync(selection) }
            }
        }
    }
    @Published private(set) var archiveStatus: String?
    @Published private(set) var encryptionStatus: String?
    @Published var settings: CaptureSettings
    @Published var provider: AIProviderConfiguration
    @Published var timeZone = TimeZone.autoupdatingCurrent
    private var queryGeneration = UUID()
    private var timelineGeneration = UUID()
    private var answerGeneration = UUID()
    private var askTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var scrubTask: Task<Void, Never>?
    private var pendingScrubDate: Date?
    private var timelineHalfSpan: TimeInterval = 4_320
    private var navigationGeneration = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var providerConfigurations: [String: AIProviderConfiguration] = [:]
    private var statusGeneration = UUID()
    private var appliedCaptureSettings: CaptureSettings?
    private var searchRootQuery: String?
    private var updatingSearchDraft = false
    private var archiveTask: Task<Void, Never>?
    private var archiveRequested = false

    init(root: URL = ReprisePaths.root, keys: VaultKeys? = nil) throws {
        self.root = root
        let keys = try keys ?? Self.libraryKeys(root: root)
        self.keys = keys
        store = try MomentStore(root: root, keys: keys)
        // MCP consent written before encryption carried no signature; keep that choice once.
        if store.convertedFromPlaintext { try? MCPAccess.adoptUnsigned(root: root, keys: keys) }
        capture = CaptureEngine(store: store, root: root)
        meeting = MeetingRecorder(store: store, root: root, languages: speechLanguages)
        archiver = FrameArchiver(store: store, root: root)
        searchHistory = SearchHistory.load(root: root, cipher: keys.cipher)
        let defaults = UserDefaults.standard
        preferences = defaults.data(forKey: "appPreferences").flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        settings = defaults.data(forKey: "captureSettings").flatMap { try? JSONDecoder().decode(CaptureSettings.self, from: $0) } ?? CaptureSettings()
        provider = defaults.data(forKey: "providerSettings").flatMap { try? JSONDecoder().decode(AIProviderConfiguration.self, from: $0) } ?? AIProviderConfiguration()
        providerConfigurations = defaults.data(forKey: "providerConfigurations").flatMap { try? JSONDecoder().decode([String: AIProviderConfiguration].self, from: $0) } ?? [:]
        $search.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, !self.updatingSearchDraft else { return }
            if self.searchTurns.isEmpty { self.invalidateAnswer() }
            else { self.searchError = nil }
        }.store(in: &subscriptions)
        $search.removeDuplicates().dropFirst().debounce(for: .milliseconds(220), scheduler: RunLoop.main).sink { [weak self] _ in
            Task { await self?.refreshMatches() }
        }.store(in: &subscriptions)
        $appFilter.removeDuplicates().dropFirst().sink { [weak self] _ in self?.filtersChanged() }.store(in: &subscriptions)
        $mode.removeDuplicates().dropFirst().sink { [weak self] _ in self?.filtersChanged() }.store(in: &subscriptions)
        $dayFilter.removeDuplicates().dropFirst().sink { [weak self] _ in self?.filtersChanged() }.store(in: &subscriptions)
        capture.$lastCapture.compactMap { $0 }.removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.reload(preserve: true) } }
            .store(in: &subscriptions)
        meeting.$lastSavedMoment.compactMap { $0 }.sink { [weak self] moment in
            guard let self else { return }
            if self.selection?.id == moment.id || self.meeting.isBusy && self.meeting.transcribingMomentID == nil {
                self.select(moment)
            }
            Task { await self.reload(preserve: true) }
        }.store(in: &subscriptions)
        // When a transcript is saved, the meeting is summarized; a later transcript replaces the summary.
        meeting.$transcribingMomentID.removeDuplicates().sink { [weak self] id in
            guard let self else { return }
            let finished = self.watchedTranscription
            self.watchedTranscription = id
            if id == nil, let finished { Task { await self.transcriptionFinished(finished) } }
        }.store(in: &subscriptions)
        $selection.compactMap { $0 }.filter { $0.kind == "meeting" }.removeDuplicates { $0.id == $1.id }.sink { [weak self] moment in
            Task { await self?.loadSummary(for: moment.id) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.timeZone = .autoupdatingCurrent; await self?.reload() }
        }.store(in: &subscriptions)
    }

    func start() async {
        applyPreferences()
        permissions.refresh()
        await reload()
        let resumeCapture = UserDefaults.standard.bool(forKey: "resumeCaptureAfterRestart")
        let interrupted = UserDefaults.standard.bool(forKey: Self.captureSessionKey)
        UserDefaults.standard.removeObject(forKey: "resumeCaptureAfterRestart")
        if !showOnboarding, preferences.startRecordingOnLaunch || resumeCapture || interrupted, CGPreflightScreenCaptureAccess() {
            await capture.start(settings: settings); appliedCaptureSettings = settings
        }
        UserDefaults.standard.set(capture.isRecording, forKey: Self.captureSessionKey)
        Task {
            let normalized = await speechLanguages.normalize(preferences.speechLocales)
            if normalized != preferences.speechLocales { preferences.speechLocales = normalized }
            else if preferences.transcribeMeetings { await speechLanguages.sync(normalized) }
        }
        startArchiving()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                guard let self else { return }
                if self.capture.isRecording || self.meeting.isRecording { await self.reload(preserve: true) }
            }
        }
        await refreshStatus()
    }

    func applyPreferences() {
        NSApp.setActivationPolicy(preferences.iconPlacement == .menuBar ? .accessory : .regular)
        NSApp.appearance = preferences.followSystemAppearance ? nil : NSAppearance(named: preferences.darkMode ? .darkAqua : .aqua)
        meetingDetector.enabled = !showOnboarding && preferences.detectMeetings
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        showOnboarding = false
        applyPreferences()
        Task { await saveSettings() }
    }

    var calendar: Calendar { var value = Calendar.autoupdatingCurrent; value.timeZone = timeZone; return value }
    var displayedMatches: [Moment] { aiMatches ?? matchingMoments }
    var query: MomentQuery {
        let range = dayFilter.map { MemoryCalendar.dayRange(containing: $0, calendar: calendar) }
        return MomentQuery(text: search, appName: appFilter, since: range?.lowerBound,
            until: range.map { $0.upperBound.addingTimeInterval(-0.000001) },
            kind: mode == "meetings" ? "meeting" : nil, limit: 200)
    }

    func reload(preserve: Bool = false) async {
        if !preserve { cancelNavigation() }
        let navigation = navigationGeneration
        let generation = UUID(); timelineGeneration = generation
        let selectedID = selection?.id
        let wasAtLatest = selection == nil || (timelineDate ?? selection?.timestamp) == stats.newest
        do {
            let oldCount = stats.momentCount
            let updatedStats = try await store.stats()
            guard generation == timelineGeneration else { return }
            stats = updatedStats
            if !preserve || moments.isEmpty || oldCount != stats.momentCount {
                var timelineQuery = query; timelineQuery.text = ""; timelineQuery.appName = nil; timelineQuery.kind = nil
                let latest = try await store.query(timelineQuery)
                guard generation == timelineGeneration else { return }
                let followLatest = wasAtLatest && selectedID == selection?.id
                if navigation == navigationGeneration && (!preserve || followLatest || latest.contains(where: { $0.id == selection?.id })) {
                    moments = latest
                    if !preserve || followLatest { selection = latest.first; timelineDate = selection?.timestamp }
                    hasMore = latest.count == timelineQuery.limit
                }
            }
            if navigation == navigationGeneration, let date = timelineDate,
               timelineAxis.entries.isEmpty || oldCount != stats.momentCount || needsTimelineOverview(at: date) {
                await refreshTimelineOverview(around: date, generation: navigation)
            }
            await refreshMatches()
            if !preserve { usages = try await store.usage(since: calendar.date(byAdding: .day, value: -30, to: Date())) }
        } catch { self.error = error.localizedDescription }
    }

    func refreshMatches() async {
        guard searchTurns.isEmpty else { return }
        let generation = UUID(); queryGeneration = generation
        do {
            let items = try await store.search(query)
            guard generation == queryGeneration else { return }
            matchingMoments = items
        } catch { if generation == queryGeneration { searchError = error.localizedDescription } }
    }

    private func filtersChanged() {
        invalidateAnswer()
        Task { await refreshMatches() }
    }

    func loadMore() async {
        var request = query; request.offset = moments.count
        do {
            let items = try await store.query(request)
            moments.append(contentsOf: items); hasMore = items.count == request.limit
        } catch { self.error = error.localizedDescription }
    }

    func select(_ moment: Moment) { cancelNavigation(); selection = moment; timelineDate = moment.timestamp }
    func step(_ direction: Int) {
        guard let selected = selection, let index = moments.firstIndex(where: { $0.id == selected.id }) else { return }
        cancelNavigation()
        let generation = navigationGeneration
        let next = index + direction
        if moments.indices.contains(next) { selection = moments[next]; timelineDate = selection?.timestamp }
        else {
            Task {
                do {
                    let adjacentMoment = try await store.adjacent(to: selected, earlier: direction > 0)
                    if let adjacentMoment, generation == navigationGeneration { await showMoment(adjacentMoment, generation: generation) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func skip(_ direction: Int, seconds: TimeInterval = 30) {
        guard let selected = selection else { return }
        cancelNavigation()
        let generation = navigationGeneration
        Task {
            do {
                let target = try await store.skip(from: selected, earlier: direction > 0, seconds: seconds)
                if let target, generation == navigationGeneration { await showMoment(target, generation: generation) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func scrub(to date: Date) {
        guard selection != nil else { return }
        let target = MemoryTimeline.clamp(date, oldest: stats.oldest, newest: stats.newest)
        if scrubTask == nil { navigationGeneration = UUID() }
        if timelineDate != target { timelineDate = target }
        if let nearest = MemoryCalendar.nearest(to: target, in: moments), selection?.id != nearest.id { selection = nearest }
        pendingScrubDate = needsMomentWindow(at: target) || needsTimelineOverview(at: target) ? target : nil
        guard pendingScrubDate != nil, scrubTask == nil else { return }
        let generation = navigationGeneration
        // One reader consumes the latest target. Continuous input must not cancel or
        // postpone database work until the gesture stops.
        scrubTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.navigationGeneration { self.scrubTask = nil } }
            while let requested = self.pendingScrubDate {
                self.pendingScrubDate = nil
                do {
                    if self.needsTimelineOverview(at: requested) {
                        await self.refreshTimelineOverview(around: requested, generation: generation)
                    }
                    guard !Task.isCancelled, generation == self.navigationGeneration else { return }
                    if self.needsMomentWindow(at: self.timelineDate ?? requested) {
                        let window = try await self.store.timeline(around: self.timelineDate ?? requested)
                        guard !Task.isCancelled, generation == self.navigationGeneration else { return }
                        let current = self.timelineDate ?? requested
                        let containsCurrent = (window.last?.timestamp ?? current) <= current && current <= (window.first?.timestamp ?? current)
                        if requested == current || containsCurrent {
                            self.moments = window
                            if let nearest = MemoryCalendar.nearest(to: current, in: window), nearest.id != self.selection?.id { self.selection = nearest }
                            self.hasMore = false
                        }
                    }
                    try await Task.sleep(for: .milliseconds(32))
                } catch {
                    if !Task.isCancelled, generation == self.navigationGeneration { self.error = error.localizedDescription }
                    return
                }
            }
        }
    }

    func scrollTimeline(x: Double, y: Double, precise: Bool) {
        guard let origin = timelineDate ?? selection?.timestamp else { return }
        moveTimeline(from: origin, by: MemoryTimeline.scrollOffset(x: x, y: y, precise: precise))
    }

    func moveTimeline(from origin: Date, by offset: TimeInterval) {
        scrub(to: timelineAxis.moving(from: origin, by: offset))
    }

    func setTimelineViewport(width: Double) {
        let span = max(320, width) * MemoryTimeline.secondsPerPoint / 2
        guard abs(span - timelineHalfSpan) > 1 else { return }
        timelineHalfSpan = span
        if let date = timelineDate, needsTimelineOverview(at: date) { scrub(to: date) }
    }

    private func needsMomentWindow(at date: Date) -> Bool {
        let index = moments.firstIndex { $0.id == selection?.id } ?? 0
        return moments.isEmpty || date < (moments.last?.timestamp ?? date) || date > (moments.first?.timestamp ?? date)
            || (index < 20 && moments.first?.timestamp != stats.newest)
            || (index >= moments.count - 20 && moments.last?.timestamp != stats.oldest)
    }

    private func needsTimelineOverview(at date: Date) -> Bool {
        guard let first = timelineAxis.entries.first, let last = timelineAxis.entries.last else { return true }
        let position = timelineAxis.position(of: date)
        let margin = timelineHalfSpan + 320
        return date < first.timestamp || date > last.timestamp
            || (first.timestamp != stats.oldest && position < margin)
            || (last.timestamp != stats.newest && timelineAxis.extent - position < margin)
    }

    private func refreshTimelineOverview(around date: Date, generation: UUID) async {
        do {
            let axis = try await store.timelineOverview(around: date, span: timelineHalfSpan + 1_600)
            guard !Task.isCancelled, generation == navigationGeneration else { return }
            let current = timelineDate ?? date
            if current == date || ((axis.entries.first?.timestamp ?? current) <= current && current <= (axis.entries.last?.timestamp ?? current)) {
                timelineAxis = axis
            }
        } catch { if !Task.isCancelled, generation == navigationGeneration { self.error = error.localizedDescription } }
    }

    func jump(to date: Date) async {
        cancelNavigation()
        await jump(to: date, generation: navigationGeneration)
    }

    private func jump(to date: Date, generation: UUID) async {
        do {
            guard let target = try await store.nearest(to: date), !Task.isCancelled, generation == navigationGeneration else { return }
            await showMoment(target, generation: generation)
        } catch { self.error = error.localizedDescription }
    }

    func openMatch(_ moment: Moment) async {
        cancelNavigation()
        await showMoment(moment, generation: navigationGeneration)
    }

    private func cancelNavigation() {
        scrubTask?.cancel(); scrubTask = nil
        pendingScrubDate = nil
        navigationGeneration = UUID()
    }

    func endTimelineInteraction() { cancelNavigation() }

    private func showMoment(_ moment: Moment, generation: UUID) async {
        guard !Task.isCancelled, generation == navigationGeneration else { return }
        selection = moment
        timelineDate = moment.timestamp
        if needsTimelineOverview(at: moment.timestamp) { await refreshTimelineOverview(around: moment.timestamp, generation: generation) }
        guard !Task.isCancelled, generation == navigationGeneration else { return }
        if !moments.contains(where: { $0.id == moment.id }) {
            do {
                let window = try await store.timeline(around: moment.timestamp)
                guard !Task.isCancelled, generation == navigationGeneration else { return }
                moments = window
                hasMore = false
            } catch { self.error = error.localizedDescription }
        }
    }

    func openCitation(_ id: String) async {
        do { if let item = try await store.moment(id: id) { await openMatch(item) } }
        catch { self.error = error.localizedDescription }
    }

    func deleteSelected() async {
        guard let selected = selection else { return }
        do {
            // A deleted screen must not live on inside a shared archive movie.
            try await store.delete(ids: [selected.id], purgeArchivedFrames: true)
            selection = nil
            if selected.archivedFrame != nil { archiveRequested = true }
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func toggleRecording() async {
        if capture.isRecording {
            await capture.stop()
            UserDefaults.standard.set(false, forKey: Self.captureSessionKey)
            UserDefaults.standard.set(true, forKey: "recordingManuallyPaused")
            NotificationCenter.default.post(name: .repriseCapturePaused, object: nil)
            return
        }
        if !CGPreflightScreenCaptureAccess() { await permissions.request(.screenCapture) }
        await capture.start(settings: settings)
        appliedCaptureSettings = settings
        if capture.isRecording {
            UserDefaults.standard.set(true, forKey: Self.captureSessionKey)
            UserDefaults.standard.set(false, forKey: "recordingManuallyPaused")
            NotificationCenter.default.post(name: .repriseCloseMemory, object: nil)
        }
        if let message = capture.lastError { error = message }
    }

    func toggleMeeting() async {
        guard !meeting.isBusy else { return }
        if meeting.isRecording {
            await meeting.stop()
            if let moment = meeting.lastSavedMoment { await openMatch(moment) }
            await reload(preserve: true)
            return
        }
        await permissions.request(.microphone)
        guard permissions.microphone == .authorized else { error = "Microphone access is disabled in System Settings."; return }
        if preferences.transcribeMeetings && !SpeechLanguages.usesSpeechAnalyzer { await permissions.request(.speech) }
        if preferences.includeSystemAudio && !CGPreflightScreenCaptureAccess() { await permissions.request(.screenCapture) }
        await meeting.start(title: meetingDetector.candidate?.title ?? "Meeting", includeSystemAudio: preferences.includeSystemAudio,
                            transcribe: preferences.transcribeMeetings, speechLocales: preferences.speechLocales)
        if !meeting.isRecording, let message = meeting.lastError { error = message }
    }

    func transcribeSelected() async {
        guard let moment = selection, moment.kind == "meeting", !meeting.isBusy, !meeting.isRecording else { return }
        if !SpeechLanguages.usesSpeechAnalyzer {
            await permissions.request(.speech)
            guard permissions.speech == .authorized else {
                error = "Allow Speech Recognition in Privacy settings before transcribing."; return
            }
        }
        await meeting.transcribeSaved(moment, locales: preferences.speechLocales)
        if selection?.id == moment.id, let updated = meeting.lastSavedMoment, updated.id == moment.id { selection = updated }
    }

    func saveSettings() async {
        providerConfigurations[provider.provider.rawValue] = provider
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "captureSettings")
        UserDefaults.standard.set(try? JSONEncoder().encode(provider), forKey: "providerSettings")
        UserDefaults.standard.set(try? JSONEncoder().encode(providerConfigurations), forKey: "providerConfigurations")
        if capture.isRecording, appliedCaptureSettings != settings { await capture.stop(); await capture.start(settings: settings); appliedCaptureSettings = settings }
    }

    func cleanLibrary() async {
        do {
            _ = try await store.prune(retentionDays: settings.retentionDays, maxBytes: Int64(settings.storageLimitGB * 1_000_000_000))
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func selectProvider(_ kind: AIProviderKind) {
        providerConfigurations[provider.provider.rawValue] = provider
        provider = providerConfigurations[kind.rawValue] ?? AIProviderConfiguration(provider: kind)
        providerStatus = nil; accountStatus = nil; availableModels = []
        cancelAnswer()
        Task { await saveSettings(); await refreshStatus() }
    }

    func refreshStatus() async {
        let config = provider; checkingProvider = true
        let token = UUID(); statusGeneration = token
        defer { if statusGeneration == token { checkingProvider = false } }
        let capabilities = await ai.status(configuration: config)
        let account = await ai.accountStatus(configuration: config)
        let options = await ai.models(configuration: config)
        guard config == provider, statusGeneration == token else { return }
        providerStatus = capabilities; accountStatus = account; availableModels = options; checkingProvider = false
    }

    func signIn() {
        guard let command = ai.loginCommand(configuration: provider) else { error = "Install the selected provider CLI or set its executable path."; return }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let line = ([command.executable.path] + command.arguments).map(quoted).joined(separator: " ")
        let note = provider.provider == .gemini ? "printf 'Sign in with Google when asked, then type /quit.\\n\\n'\n" : ""
        openTerminal(name: "Sign-In", lines: "unset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN XAI_API_KEY GROK_API_KEY GEMINI_API_KEY CURSOR_API_KEY\nexport GROK_DISABLE_API_KEY_AUTH=1\n\(note)\(line)\nprintf '\\nReturn to Reprise and check sign-in. Press Return to close.\\n'")
    }

    /// Runs the vendor's own installer in Terminal, so each step and any password prompt stay visible.
    func installProvider() {
        let kind = provider.provider
        if kind == .apple { openAppleIntelligenceSettings(); return }
        guard let command = kind.installScript else { return }
        let echoed = command.replacingOccurrences(of: "'", with: "'\\''")
        openTerminal(name: "Install", lines: "printf 'Installing \(kind.displayName) with its official installer:\\n  %s\\n\\n' '\(echoed)'\n\(command)\nprintf '\\nWhen it finishes, return to Reprise and choose Refresh. Press Return to close.\\n'")
    }

    private func openTerminal(name: String, lines: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Reprise-Login", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("\(provider.provider.displayName.replacingOccurrences(of: " ", with: "-"))-\(name).command")
            let script = "#!/bin/zsh\n\(lines)\nread -r\nrm -- \"$0\"\n"
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NotificationCenter.default.post(name: .repriseCloseMemory, object: nil)
            NSWorkspace.shared.open(file)
        } catch { self.error = error.localizedDescription }
    }

    func openAppleIntelligenceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func startOllama() {
        let app = URL(fileURLWithPath: "/Applications/Ollama.app")
        guard FileManager.default.fileExists(atPath: app.path) else { error = "Open Ollama, or start it with \"ollama serve\" in Terminal."; return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
            let message = failure?.localizedDescription
            Task { @MainActor in
                if let message { self.error = message; return }
                // The server takes a moment to accept connections after the app opens.
                for _ in 0..<20 where await Ollama.version() == nil { try? await Task.sleep(for: .milliseconds(500)) }
                await self.refreshStatus()
            }
        }
    }

    func downloadModel(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelDownload == nil, !name.isEmpty else { return }
        modelDownload = (name, nil, "Starting")
        Task {
            do {
                try await Ollama.pull(name) { fraction, status in
                    Task { @MainActor in self.modelDownload = (name, fraction, status) }
                }
                modelDownload = nil
                if provider.provider == .ollama { provider.model = name; await saveSettings() }
            } catch {
                modelDownload = nil
                self.error = error.localizedDescription
            }
            await refreshStatus()
        }
    }

    // MARK: Meeting summaries

    func loadSummary(for id: String) async {
        guard summaries[id] == nil, let saved = try? await store.summary(for: id) else { return }
        summaries[id] = saved
    }

    private func transcriptionFinished(_ id: String) async {
        guard preferences.summarizeMeetings, let moment = try? await store.moment(id: id), moment.kind == "meeting",
              !moment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await loadSummary(for: id)
        if let summary = summaries[id], summary.matches(moment) { return }
        await summarize(moment, automatic: true)
    }

    /// Summarizes with the chosen provider. An automatic summary ends with a notification; a failed
    /// one stays on the recording with a Try Again button rather than interrupting.
    func summarize(_ moment: Moment, automatic: Bool = false) async {
        let id = moment.id
        guard moment.kind == "meeting", !summarizing.contains(id) else { return }
        guard !moment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryErrors[id] = "Transcribe this recording first."; return
        }
        let config = provider
        summarizing.insert(id); summaryErrors[id] = nil
        defer { summarizing.remove(id) }
        if accountStatus == nil { await refreshStatus() }
        guard accountStatus?.signedIn != false else {
            summaryErrors[id] = "Sign in to \(config.provider.displayName) in AI & Models, then try again."; return
        }
        do {
            let result = try await MeetingSummarizer(client: ai).summarize(moment, configuration: config)
            for entry in result.usage { try? await store.recordUsage(entry) }
            try await store.saveSummary(result.summary, for: id)
            summaries[id] = result.summary
            if automatic { notifySummary(moment) }
        } catch {
            let failure = error as? MeetingSummaryFailure
            for entry in failure?.usage ?? [] { try? await store.recordUsage(entry) }
            summaryErrors[id] = (failure?.underlyingError ?? error).localizedDescription
        }
        usages = (try? await store.usage(since: calendar.date(byAdding: .day, value: -30, to: Date()))) ?? usages
    }

    /// The notification names the meeting but carries none of the summary, because Notification
    /// Center keeps its own unencrypted history.
    private func notifySummary(_ moment: Moment) {
        let center = UNUserNotificationCenter.current()
        let title = moment.windowTitle.isEmpty ? "Meeting" : moment.windowTitle
        let id = moment.id
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Meeting summary ready"
            content.subtitle = title
            content.body = "Open Reprise to read the key points, decisions and action items."
            content.userInfo = ["momentID": id]
            center.add(UNNotificationRequest(identifier: "summary-\(id)", content: content, trigger: nil))
        }
    }

    func openMemory(id: String) async {
        searchPresented = false
        NotificationCenter.default.post(name: .repriseOpenMemory, object: nil)
        await openCitation(id)
    }

    // MARK: Recovery key

    /// The library's recovery key, shown only after the Mac's owner authenticates.
    func revealRecoveryKey() async throws -> String {
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the recovery key for your Reprise library")
        guard let key = try VaultKeychain.load(root: root) else { throw VaultKeychain.Failure.missing }
        return RecoveryKey.encode(key)
    }
    func ask() {
        let input = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asking, !input.isEmpty else { return }
        let previousTurns = searchTurns
        let rootQuery = searchRootQuery ?? input
        searchHistory.record(rootQuery)
        saveSearchHistory()
        guard stats.momentCount > 0 else { searchError = "No memories yet. Record a screen or meeting, or import images first."; return }
        guard accountStatus?.signedIn != false else {
            searchError = provider.provider.hasSignIn ? "Sign in to your \(provider.provider.displayName) subscription in AI & Models before searching."
                : "\(provider.provider.displayName): \(accountStatus?.message ?? "not ready"). Open AI & Models."
            return
        }
        asking = true; pendingQuestion = input; searchError = nil; searchNotice = nil; restoredSearchDate = nil
        if previousTurns.isEmpty { response = nil; aiMatches = [] }
        setSearchDraft("")
        let config = provider; let token = UUID(); answerGeneration = token
        let savedDay = dayFilter
        var filter = query; filter.text = ""
        askTask = Task {
            defer { if answerGeneration == token { asking = false; pendingQuestion = nil } }
            do {
                let result = try await MemorySearch(store: store, client: ai).search(question: input, configuration: config, filter: filter, timeZone: timeZone, conversation: previousTurns)
                for entry in result.usage { try await store.recordUsage(entry) }
                guard !Task.isCancelled, answerGeneration == token else { return }
                response = result.response; aiMatches = result.moments
                searchTurns = Array((previousTurns + [MemorySearchTurn(question: input, response: result.response)]).suffix(12))
                searchRootQuery = rootQuery
                searchHistory.record(rootQuery, result: SavedSearchResult(response: result.response, moments: result.moments,
                    appName: filter.appName, kind: filter.kind, day: savedDay, turns: searchTurns))
                saveSearchHistory()
                usages = try await store.usage(since: calendar.date(byAdding: .day, value: -30, to: Date()))
            } catch {
                if !Task.isCancelled, answerGeneration == token, search.isEmpty { setSearchDraft(input) }
                if let failure = error as? MemorySearchFailure {
                    for entry in failure.usage { try? await store.recordUsage(entry) }
                    if !Task.isCancelled, answerGeneration == token { searchError = failure.underlyingError.localizedDescription }
                } else if !Task.isCancelled, answerGeneration == token { searchError = error.localizedDescription }
                usages = (try? await store.usage(since: calendar.date(byAdding: .day, value: -30, to: Date()))) ?? usages
            }
        }
    }
    private func setSearchDraft(_ value: String) {
        updatingSearchDraft = true; search = value; updatingSearchDraft = false
    }
    func cancelAnswer() {
        if let pendingQuestion, search.isEmpty { setSearchDraft(pendingQuestion) }
        answerGeneration = UUID(); askTask?.cancel(); askTask = nil; asking = false; pendingQuestion = nil
    }
    private func invalidateAnswer() {
        cancelAnswer(); response = nil; aiMatches = nil; searchError = nil; searchNotice = nil; restoredSearchDate = nil
        searchTurns = []; searchRootQuery = nil
    }

    func startNewSearch() { invalidateAnswer(); setSearchDraft(""); Task { await refreshMatches() } }

    @discardableResult func dismissSearch() -> Bool {
        guard searchPresented else { return false }
        searchPresented = false
        return true
    }

    func restoreSearch(_ query: String) async {
        let saved = searchHistory.result(for: query)
        invalidateAnswer()
        search = query
        appFilter = saved?.appName; mode = saved?.kind == "meeting" ? "meetings" : "all"; dayFilter = saved?.day
        // Filter invalidation is synchronous; no later view callback may erase the restored answer.
        let token = answerGeneration
        searchHistory.record(query); saveSearchHistory()
        aiMatches = []
        guard let saved else {
            searchNotice = "This older search has no saved answer. Submit it to search again."
            return
        }
        do {
            let result = try await saved.restore(from: store)
            guard !Task.isCancelled, token == answerGeneration else { return }
            response = result.response; aiMatches = result.moments; restoredSearchDate = saved.savedAt
            searchTurns = result.turns.isEmpty ? [MemorySearchTurn(question: query, response: result.response)] : result.turns
            searchRootQuery = query
            setSearchDraft("")
            if result.missingCount > 0 { searchNotice = "\(result.missingCount) original supporting memories are no longer in this vault." }
        } catch {
            if token == answerGeneration { searchNotice = "The saved answer could not be opened. No new search was run." }
        }
    }

    private func saveSearchHistory() {
        do { try searchHistory.save(root: root, cipher: cipher) }
        catch { self.error = "Could not save recent searches: \(error.localizedDescription)" }
    }

    func endSearchSession() {
        invalidateAnswer()
        searchPresented = false
        search = ""; matchingMoments = []
        appFilter = nil; mode = "all"; dayFilter = nil
        cancelNavigation()
    }

    func importImages() async {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        busy = true; defer { busy = false }
        do {
            for url in panel.urls {
                let moment = try await ImageImporter.shared.importFile(url, root: root, cipher: cipher)
                try await store.insert(moment)
            }
            dayFilter = nil; search = ""; await reload()
        } catch { self.error = error.localizedDescription }
    }

    func exportLibrary() async {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Reprise-memories.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try await store.export(to: url, query: query) } catch { self.error = error.localizedDescription }
    }

    /// The library key from the login keychain, created on first use. A library that is already
    /// encrypted never gets a new key: nothing sealed with the old one could be read with it.
    /// Checks a recovery key against the library before it goes into the keychain.
    nonisolated static func restoreLibraryKey(_ text: String, root: URL = ReprisePaths.root) throws {
        let key = try RecoveryKey.decode(text)
        guard MomentStore.canUnlock(root: root, keys: VaultKeys(master: key)) else { throw RecoveryKey.Failure.wrongLibrary }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RepriseMCP")
        let programs: [URL?] = FileManager.default.isExecutableFile(atPath: helper.path) ? [nil, helper] : [nil]
        try VaultKeychain.restore(key, root: root, trusting: programs)
    }

    nonisolated static func libraryKeys(root: URL) throws -> VaultKeys {
        if let master = try VaultKeychain.load(root: root) { return VaultKeys(master: master) }
        guard !MomentStore.isEncryptedLibrary(root: root) else { throw VaultKeychain.Failure.missing }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RepriseMCP")
        let programs: [URL?] = FileManager.default.isExecutableFile(atPath: helper.path) ? [nil, helper] : [nil]
        return VaultKeys(master: try VaultKeychain.create(root: root, trusting: programs))
    }

    func shutdown() { heartbeat?.cancel(); askTask?.cancel(); scrubTask?.cancel(); archiveTask?.cancel(); meetingDetector.stop() }

    /// Quit and pause close the session; a power-off with recording on resumes it at the next launch.
    func endCaptureSession(poweringOff: Bool) {
        if poweringOff && capture.isRecording { UserDefaults.standard.set(true, forKey: "resumeCaptureAfterRestart") }
        UserDefaults.standard.set(false, forKey: Self.captureSessionKey)
    }

    /// Compresses older screens every ten minutes, faster while a backlog remains, and re-encodes
    /// movies that held deleted screens. Files from before encryption are sealed first, and
    /// interrupted leftovers are swept once per launch.
    private func startArchiving() {
        archiveTask?.cancel()
        archiveTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            var swept = false
            while !Task.isCancelled {
                guard let self else { return }
                let unsealed = await self.sealLegacyMedia()
                let thumbnails = await self.upgradeThumbnails()
                let backlog = await self.archiveOnce() || unsealed || thumbnails
                if !swept {
                    swept = true
                    _ = try? await self.store.removeUnreferencedMedia()
                }
                var waited = 0.0
                while waited < (backlog ? 5 : 600), !self.archiveRequested {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    waited += 5
                }
                self.archiveRequested = false
            }
        }
    }

    /// Seals one batch of media written before encryption. Returns whether more remain.
    private func sealLegacyMedia() async -> Bool {
        guard let referenced = try? await store.referencedMedia() else { return false }
        let root = self.root, cipher = self.cipher, inUse = meeting.mediaInUse
        let progress = await Task.detached(priority: .utility) {
            VaultMigration.sealLegacyFiles(root: root, cipher: cipher, referenced: referenced, inUse: inUse)
        }.value
        encryptionStatus = progress.failure.map { "Some files are not encrypted yet: \($0)" }
        return progress.remaining
    }

    /// Re-encodes one batch of old JPEG thumbnails as HEIC and keeps the open timeline pointing at
    /// them. Returns whether more remain.
    private func upgradeThumbnails() async -> Bool {
        guard let result = try? await archiver.upgradeThumbnails() else { return false }
        if !result.paths.isEmpty {
            func updated(_ moment: Moment) -> Moment {
                guard let path = result.paths[moment.id] else { return moment }
                var moment = moment
                moment.thumbnailPath = path
                return moment
            }
            moments = moments.map(updated)
            if let selection { self.selection = updated(selection) }
        }
        return result.remaining
    }

    private func archiveOnce() async -> Bool {
        let settings = self.settings
        var moved: [String: FrameArchiver.ArchivedFrame] = [:]
        var backlog = false
        do {
            moved = try await archiver.purgeDeletedFrames(quality: settings.archiveQuality)
            if settings.archiveOlderFrames {
                let report = try await archiver.archiveDue(quality: settings.archiveQuality)
                moved.merge(report.frames) { _, latest in latest }
                backlog = report.backlog
                archiveStatus = report.failure
            } else { archiveStatus = nil }
            if settings.compactOlderFrames {
                let cutoff = Date().addingTimeInterval(-Double(max(1, settings.compactAfterDays)) * 86_400)
                let report = try await archiver.compactMovies(before: cutoff, quality: settings.archiveQuality)
                moved.merge(report.frames) { _, latest in latest }
                backlog = backlog || report.backlog
                if let failure = report.failure { archiveStatus = failure }
            }
        } catch is CancellationError { return false }
        catch { archiveStatus = error.localizedDescription }
        guard !moved.isEmpty else { return backlog }
        // The library now points at movie frames; keep the open timeline in step with it.
        func located(_ moment: Moment) -> Moment {
            guard let frame = moved[moment.id] else { return moment }
            var moment = moment
            moment.imagePath = ""; moment.videoPath = frame.videoPath; moment.videoOffset = frame.offset
            return moment
        }
        moments = moments.map(located)
        if let selection, moved[selection.id] != nil { self.selection = located(selection) }
        if let updated = try? await store.stats() { stats = updated }
        return backlog
    }
}

actor ImageImporter {
    static let shared = ImageImporter()
    func importFile(_ url: URL, root: URL, cipher: VaultCipher) throws -> Moment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let id = UUID().uuidString; let relative = "imports/\(id).jpg"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        try cipher.write(encoded as Data, to: destination)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US", "ko-KR"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Moment(id: id, timestamp: attributes.contentModificationDate ?? Date(), appName: "Imported", windowTitle: url.lastPathComponent, text: text, imagePath: relative, thumbnailPath: relative, byteCount: size)
    }
}
