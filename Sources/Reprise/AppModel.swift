import AppKit
import AVFoundation
import Combine
import ImageIO
import IOKit.ps
import LocalAuthentication
import RepriseCore
import RepriseMCPKit
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
    /// Opens only the search box, with nothing behind it. It has no default and stays unset until recorded.
    let searchOnlyShortcut = GlobalShortcut(storageKey: "searchOnlyShortcut", identifier: 2, standard: nil)
    /// Turns live captions on and off; Record Meeting starts and stops a recording. Neither has a default.
    let captionsShortcut = GlobalShortcut(storageKey: "captionsShortcut", identifier: 3, standard: nil)
    let meetingShortcut = GlobalShortcut(storageKey: "meetingShortcut", identifier: 4, standard: nil)
    /// Live captions over the screen, translated as they are heard.
    let captions = LiveCaptions()
    /// Opens the meeting assistant, and answers the last question the others asked. Neither has a default.
    let assistantShortcut = GlobalShortcut(storageKey: "assistantShortcut", identifier: 5, standard: nil)
    let answerShortcut = GlobalShortcut(storageKey: "answerShortcut", identifier: 6, standard: nil)
    /// Listens to a meeting and answers questions fast.
    let assistant: MeetingAssistant
    /// The assistant opened with a meeting recording and closes when it stops.
    private var assistantOpenedByMeeting = false
    /// The overlay shows only the search box until a memory is opened from it.
    @Published var searchOnly = false
    let speechLanguages = SpeechLanguages()
    /// Whisper and the speaker model, downloaded on request and run on this Mac.
    let speechModels: LocalSpeechModels
    let archiver: FrameArchiver
    /// Set while screen recording runs; still set at launch means the last run ended without
    /// Pause or Quit, such as a crash, force quit or power loss, so recording resumes.
    static let captureSessionKey = "captureSessionOpen"
    /// Given for the launch after Reprise restarted on its own: it comes back as it was, in the background.
    static let quietLaunchKey = "RepriseQuietLaunch"
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
    /// The recording open in its panel above the bottom bar. Only a choice opens one: its lane under
    /// the timeline, a search result, a citation or a notification. Moving through the timeline,
    /// which shows screens, never does.
    @Published private(set) var openRecording: Moment?
    /// Where playback starts when a recording opens part-way through, in seconds.
    @Published var recordingOffset: TimeInterval?
    /// The time a recording stays open for while the timeline moves.
    private var recordingSpan: ClosedRange<Date>?
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
    @Published var availableModels: [AIModelOption] = [] {
        didSet { modelFamilies = AIModelFamily.families(availableModels) }
    }
    @Published private(set) var modelFamilies: [AIModelFamily] = []
    /// Thinking levels the provider takes as a flag for the chosen model.
    @Published private(set) var thinkingLevels: [String] = []
    /// What Fast mode costs when the provider takes it as a setting for the chosen model.
    @Published private(set) var fastSettingNote: String?
    /// The context windows the provider's CLI offers for the chosen model, with its default.
    @Published private(set) var contextWindows: (standard: Int, options: [Int])?
    /// Screens still waiting to have their text read.
    @Published private(set) var screensToReread = 0
    /// Every memory in the time a quick search names, when only part of it is shown.
    @Published private(set) var searchTimeTotal: Int?
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
            // Choosing Whisper or speaker labels downloads what they need, with progress in Audio settings.
            if preferences.transcriptionEngine == .whisperKit,
               oldValue.transcriptionEngine != .whisperKit || oldValue.whisperModel != preferences.whisperModel {
                speechModels.download(preferences.whisperModel)
            }
            if preferences.speakerLabels && !oldValue.speakerLabels { speechModels.downloadSpeakers() }
            // Running captions follow a new language, input or account at once; their look changes as it is set.
            captions.style = preferences.captions
            if captions.isRunning, preferences.captions.listening != oldValue.captions.listening || preferences.openAIAccess != oldValue.openAIAccess {
                Task { await startCaptions() }
            }
            // Answer settings apply to the next question, new tools at once; a different way of listening starts over.
            assistant.preferences = preferences.assistant
            if assistant.isRunning, preferences.assistant.listeningKey != oldValue.assistant.listeningKey || preferences.openAIAccess != oldValue.openAIAccess {
                Task { await startAssistant() }
            } else if preferences.assistant.toolsKey != oldValue.assistant.toolsKey {
                assistant.refreshTools(preferences.assistant, web: webSearchTools())
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
    /// When the whole library was last counted; see `reload(preserve:afterCapture:)`.
    private var statsCountedAt: Date?
    private var providerConfigurations: [String: AIProviderConfiguration] = [:]
    private var statusGeneration = UUID()
    private var appliedCaptureSettings: CaptureSettings?
    private var searchRootQuery: String?
    private var updatingSearchDraft = false
    private var archiveTask: Task<Void, Never>?
    private var archiveRequested = false
    private var rereadTask: Task<Void, Never>?

    /// `models` is where speech models are kept; every library on this Mac shares one folder by default.
    init(root: URL = ReprisePaths.root, keys: VaultKeys? = nil, models: URL? = nil) throws {
        self.root = root
        speechModels = models.map { LocalSpeechModels(directory: $0) } ?? LocalSpeechModels()
        let keys = try keys ?? Self.libraryKeys(root: root)
        self.keys = keys
        store = try MomentStore(root: root, keys: keys)
        // MCP consent written before encryption carried no signature; keep that choice once.
        if store.convertedFromPlaintext { try? MCPAccess.adoptUnsigned(root: root, keys: keys) }
        capture = CaptureEngine(store: store, root: root)
        meeting = MeetingRecorder(store: store, root: root, languages: speechLanguages, speechModels: speechModels)
        assistant = MeetingAssistant(store: store, ai: ai)
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
            .sink { [weak self] _ in Task { await self?.reload(preserve: true, afterCapture: true) } }
            .store(in: &subscriptions)
        meeting.$lastSavedMoment.compactMap { $0 }.sink { [weak self] moment in
            guard let self else { return }
            // An open recording picks up its new transcript; a newly saved one opens for its time.
            if self.openRecording?.id == moment.id { self.openRecording = moment }
            else if self.meeting.isBusy && self.meeting.transcribingMomentID == nil {
                self.openRecording = moment; self.recordingOffset = nil
                let end = moment.timestamp.addingTimeInterval(moment.audioDuration ?? 0)
                self.recordingSpan = moment.timestamp.addingTimeInterval(-60)...end.addingTimeInterval(60)
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
        $openRecording.compactMap { $0 }.removeDuplicates { $0.id == $1.id }.sink { [weak self] moment in
            Task { await self?.loadSummary(for: moment.id) }
        }.store(in: &subscriptions)
        // The recording stays open while the timeline is within its time.
        $timelineDate.compactMap { $0 }.sink { [weak self] date in
            guard let self, let span = self.recordingSpan, !span.contains(date) else { return }
            self.closeRecording()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.timeZone = .autoupdatingCurrent; await self?.reload() }
        }.store(in: &subscriptions)
        captions.style = preferences.captions
        assistant.preferences = preferences.assistant
        // The assistant a recording opened closes with it, however the recording ends.
        meeting.$isRecording.removeDuplicates().sink { [weak self] recording in
            guard let self, !recording, self.assistantOpenedByMeeting else { return }
            self.assistantOpenedByMeeting = false
            self.assistant.stop()
        }.store(in: &subscriptions)
        // Like meeting recordings, live listening never resumes by itself after the Mac sleeps or the user switches away.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.stopListening() }
            }.store(in: &subscriptions)
        }
    }

    func start() async {
        applyPreferences()
        permissions.refresh()
        await reload()
        let resumeCapture = UserDefaults.standard.bool(forKey: "resumeCaptureAfterRestart")
        let interrupted = UserDefaults.standard.bool(forKey: Self.captureSessionKey)
        UserDefaults.standard.removeObject(forKey: "resumeCaptureAfterRestart")
        let restarted = UserDefaults.standard.bool(forKey: Self.quietLaunchKey)
        if !showOnboarding, restarted ? resumeCapture : preferences.startRecordingOnLaunch || resumeCapture || interrupted,
           CGPreflightScreenCaptureAccess() {
            await capture.start(settings: settings); appliedCaptureSettings = settings
        }
        UserDefaults.standard.set(capture.isRecording, forKey: Self.captureSessionKey)
        Task {
            let normalized = await speechLanguages.normalize(preferences.speechLocales)
            if normalized != preferences.speechLocales { preferences.speechLocales = normalized }
            else if preferences.transcribeMeetings { await speechLanguages.sync(normalized) }
        }
        startArchiving()
        startRereadingScreens()
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
    var displayedMatches: [Moment] {
        if let aiMatches { return aiMatches }
        // A filter change applies at once to what is already listed; the refreshed list follows.
        return matchingMoments.filter { (mode != "meetings" || $0.kind == "meeting") && (appFilter == nil || $0.appName == appFilter) }
    }
    var query: MomentQuery {
        let range = dayFilter.map { MemoryCalendar.dayRange(containing: $0, calendar: calendar) }
        return MomentQuery(text: search, appName: appFilter, since: range?.lowerBound,
            until: range.map { $0.upperBound.addingTimeInterval(-0.000001) },
            kind: mode == "meetings" ? "meeting" : nil, limit: 200)
    }

    /// `afterCapture` counts only the moments saved since the last count, reading the whole library
    /// at most once a minute: a full count on every capture read the encrypted table each time.
    func reload(preserve: Bool = false, afterCapture: Bool = false) async {
        if !preserve { cancelNavigation() }
        let navigation = navigationGeneration
        let generation = UUID(); timelineGeneration = generation
        let selectedID = selection?.id
        let wasAtLatest = selection == nil || (timelineDate ?? selection?.timestamp) == stats.newest
        do {
            let oldCount = stats.momentCount
            let updatedStats: LibraryStats
            if afterCapture, let counted = statsCountedAt, Date().timeIntervalSince(counted) < 60 {
                updatedStats = try await store.stats(after: stats)
            } else {
                updatedStats = try await store.stats()
                statsCountedAt = Date()
            }
            guard generation == timelineGeneration else { return }
            stats = updatedStats
            if !preserve || moments.isEmpty || oldCount != stats.momentCount {
                let timelineQuery = self.timelineQuery
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

    /// The timeline's screens: every app, within the chosen day.
    private var timelineQuery: MomentQuery {
        var request = query; request.text = ""; request.appName = nil; request.kind = nil; request.screensOnly = true
        return request
    }

    /// Latest memory: the newest screen shows at once, then the library is counted behind it. The
    /// button used to reload first, counting every memory before anything moved, and a scroll in
    /// the meantime dropped the jump.
    func showLatest() async {
        // A day filter limited the loaded screens to that day.
        let dayLimited = dayFilter != nil
        search = ""; dayFilter = nil; appFilter = nil
        cancelNavigation()
        let navigation = navigationGeneration
        if dayLimited || moments.first == nil || moments.first?.timestamp != stats.newest {
            do {
                let request = timelineQuery
                let latest = try await store.query(request)
                guard navigation == navigationGeneration else { return }
                moments = latest; hasMore = latest.count == request.limit
            } catch { self.error = error.localizedDescription; return }
        }
        selection = moments.first; timelineDate = selection?.timestamp
        await reload(preserve: true)
    }

    /// Time words in the quick search, such as 오늘 or 어제 저녁, read as a time range.
    var searchTime: QuickSearchTime? { searchTurns.isEmpty ? QuickSearchTime.parse(search, calendar: calendar) : nil }

    /// The live search: the visible filters, narrowed to the time the words name.
    var searchQuery: MomentQuery {
        var request = query
        guard let time = searchTime else { return request }
        request.text = time.text
        let end = time.interval.end.addingTimeInterval(-0.000001)
        request.since = max(request.since ?? time.interval.start, time.interval.start)
        request.until = min(request.until ?? end, end)
        return request
    }

    func refreshMatches() async {
        guard searchTurns.isEmpty else { return }
        let generation = UUID(); queryGeneration = generation
        do {
            var request = searchQuery
            var items: [Moment], total: Int?
            // A time word alone shows that whole time: distinct activities across it, newest first.
            if searchTime != nil, request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.limit = 96
                let overview = try await store.activityOverview(request)
                items = overview.moments.sorted { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
                total = overview.coverage?.totalRecords
            } else { items = try await store.search(request) }
            guard generation == queryGeneration else { return }
            matchingMoments = items; searchTimeTotal = total
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
        // A recording opens in its panel, over the screens of its time.
        if moment.kind == "meeting" { await openRecording(moment); return }
        searchOnly = false
        cancelNavigation()
        await showMoment(moment, generation: navigationGeneration)
    }

    /// Opens a recording, at `date` when it is chosen part-way through, and moves the timeline there.
    func openRecording(_ moment: Moment, at date: Date? = nil) async {
        guard moment.kind == "meeting" else { return }
        searchOnly = false
        recordingSpan = nil
        openRecording = moment
        let start = moment.timestamp, end = start.addingTimeInterval(moment.audioDuration ?? 0)
        let target = min(end, max(start, date ?? start))
        let offset = target.timeIntervalSince(start)
        recordingOffset = offset >= 1 ? offset : nil
        await jump(to: target)
        guard openRecording?.id == moment.id else { return }
        // The nearest screen can sit just outside a recording, so the span includes it.
        let landed = timelineDate ?? target
        recordingSpan = min(start, landed).addingTimeInterval(-60)...max(end, landed).addingTimeInterval(60)
    }

    func openRecording(id: String, at date: Date? = nil) async {
        do { if let moment = try await store.moment(id: id) { await openRecording(moment, at: date) } }
        catch { self.error = error.localizedDescription }
    }

    func closeRecording() {
        openRecording = nil; recordingSpan = nil; recordingOffset = nil
    }

    func deleteRecording() async {
        guard let recording = openRecording else { return }
        do {
            try await store.delete(ids: [recording.id])
            closeRecording()
            await reload(preserve: true)
        } catch { self.error = error.localizedDescription }
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
        // The window stays open: capture skips screens while Reprise is visible and saves again
        // once it closes. Closing it here felt like the app was shutting down.
        if capture.isRecording {
            UserDefaults.standard.set(true, forKey: Self.captureSessionKey)
            UserDefaults.standard.set(false, forKey: "recordingManuallyPaused")
        }
        if let message = capture.lastError { error = message }
    }

    /// `announce` tells, in a notification, what a shortcut did while Reprise stayed out of sight.
    func toggleMeeting(announce: Bool = false) async {
        guard announce else { await toggleMeeting(); return }
        let stopping = meeting.isRecording
        error = nil
        await toggleMeeting()
        if let message = error {
            error = nil
            notify("The meeting was not recorded", message)
        } else if stopping {
            notify("Meeting saved", "Open Reprise to play it and read its transcript.", momentID: meeting.lastSavedMoment?.id)
        } else if meeting.isRecording {
            notify("Recording the meeting", "Press the same shortcut to stop and save.")
        }
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
                            transcribe: preferences.transcribeMeetings, request: transcriptionRequest())
        if !meeting.isRecording, let message = meeting.lastError { error = message }
        if meeting.isRecording, preferences.assistant.openWithMeetings, !assistant.isRunning {
            await startAssistant()
            assistantOpenedByMeeting = true
        }
    }

    /// Turns live captions on or off.
    func toggleCaptions() async {
        if captions.isRunning { captions.stop() } else { await startCaptions() }
    }

    /// Starts captions with the settings as they are, after asking for what the chosen input needs.
    func startCaptions() async {
        switch preferences.captions.input {
        case .system: if !CGPreflightScreenCaptureAccess() { await permissions.request(.screenCapture) }
        case .microphone: await permissions.request(.microphone)
        }
        captions.start(preferences.captions, access: preferences.openAIAccess, codexPath: codexPath, keep: speechLanguages)
    }

    /// Shows the captions to drag into place, also before they start.
    func moveCaptions() { captions.moving = true }

    /// Stops live captions and the meeting assistant.
    func stopListening() {
        if captions.isRunning { captions.stop() }
        if assistant.isRunning { assistant.stop(); assistantOpenedByMeeting = false }
    }

    /// Opens or closes the meeting assistant.
    func toggleAssistant() async {
        if assistant.isRunning { assistant.stop(); assistantOpenedByMeeting = false } else { await startAssistant() }
    }

    /// Starts the assistant, after asking for the microphone and for Mac audio.
    func startAssistant() async {
        await permissions.request(.microphone)
        if !CGPreflightScreenCaptureAccess() { await permissions.request(.screenCapture) }
        let provider = { [weak self] in self?.provider ?? AIProviderConfiguration() }
        assistant.start(preferences.assistant, meetingLanguages: preferences.speechLocales, access: preferences.openAIAccess,
                        codexPath: codexPath, provider: provider, languages: speechLanguages,
                        web: webSearchTools(), secrets: { MCPServerKeychain.load($0) })
    }

    /// The CLIs and keys web search can use, as AI & Models has them set up.
    func webSearchTools() -> WebSearch.Tools {
        func configuration(_ kind: AIProviderKind) -> AIProviderConfiguration {
            provider.provider == kind ? provider : providerConfigurations[kind.rawValue] ?? AIProviderConfiguration(provider: kind)
        }
        return WebSearch.Tools(codex: configuration(.codex), claude: configuration(.claude),
                               openAIByKey: preferences.openAIAccess == .apiKey, provider: provider.provider)
    }

    /// Answers the last question the others asked, opening the assistant first when it is closed.
    func answerLastQuestion() async {
        if !assistant.isRunning { await startAssistant(); return }
        assistant.answerLast()
    }

    /// The settings a transcription starts with; `engine` picks another engine for this one time.
    func transcriptionRequest(_ engine: TranscriptionEngine? = nil) -> TranscriptionRequest {
        TranscriptionRequest(engine: engine ?? preferences.transcriptionEngine, locales: preferences.speechLocales,
                             openAIModel: preferences.openAITranscriptionModel, openAIAccess: preferences.openAIAccess,
                             whisperModel: preferences.whisperModel, geminiAccess: preferences.geminiAccess,
                             geminiModel: preferences.geminiTranscriptionModel, speakerLabels: preferences.speakerLabels,
                             speakerFinder: preferences.speakerFinder, codexPath: codexPath, geminiPath: geminiPath)
    }

    /// The Codex chosen in AI & Models, also when another provider answers searches.
    var codexPath: String? {
        let codex = provider.provider == .codex ? provider : providerConfigurations[AIProviderKind.codex.rawValue]
        return codex?.executablePath
    }

    /// The Antigravity chosen in AI & Models, also when another provider answers searches.
    var geminiPath: String? {
        let gemini = provider.provider == .gemini ? provider : providerConfigurations[AIProviderKind.gemini.rawValue]
        return gemini?.executablePath
    }

    func transcribeRecording(with engine: TranscriptionEngine? = nil) async {
        guard let moment = openRecording, !meeting.isBusy, !meeting.isRecording else { return }
        let request = transcriptionRequest(engine)
        if request.engine == .apple && !SpeechLanguages.usesSpeechAnalyzer {
            await permissions.request(.speech)
            guard permissions.speech == .authorized else {
                error = "Allow Speech Recognition in Privacy settings before transcribing."; return
            }
        }
        await meeting.transcribeSaved(moment, request: request)
        if openRecording?.id == moment.id, let updated = meeting.lastSavedMoment, updated.id == moment.id { openRecording = updated }
    }

    /// Gives one speaker of a recording a name, in its transcript and text.
    func renameSpeaker(_ speaker: String, to name: String, in moment: Moment) async {
        guard let segments = moment.transcriptSegments, !meeting.isBusy || meeting.transcribingMomentID != moment.id else { return }
        let renamed = SpeakerLabels.rename(speaker, to: name, in: segments)
        guard renamed != segments else { return }
        do {
            try await store.updateTranscript(id: moment.id, text: SpeakerLabels.text(renamed), segments: renamed, note: moment.transcriptionNote)
            guard let updated = try await store.moment(id: moment.id) else { return }
            if openRecording?.id == moment.id { openRecording = updated }
            await reload(preserve: true)
        } catch { self.error = "The speaker could not be renamed: \(error.localizedDescription)" }
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
        providerStatus = nil; accountStatus = nil; availableModels = []; thinkingLevels = []; fastSettingNote = nil; contextWindows = nil
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
        let (levels, fastNote, windows) = await Task.detached { Self.modelSettings(config) }.value
        guard config == provider, statusGeneration == token else { return }
        providerStatus = capabilities; accountStatus = account; availableModels = options; checkingProvider = false
        thinkingLevels = levels; fastSettingNote = fastNote; contextWindows = windows
    }

    /// What the provider's CLI offers for the chosen model, read from its own files off the main thread.
    private nonisolated static func modelSettings(_ config: AIProviderConfiguration) -> ([String], String?, (standard: Int, options: [Int])?) {
        (config.provider.thinkingLevels(model: config.model), config.provider.fastSettingNote(model: config.model),
         config.provider.contextWindows(model: config.model))
    }

    // MARK: Model and thinking level

    struct Choice: Identifiable, Hashable { let id: String; let name: String }

    /// Gemini and Cursor name the thinking level in the model, so they list model families.
    private var levelsInModel: Bool { [.gemini, .cursor].contains(provider.provider) }

    /// The model a search will use: the chosen one, or the automatic Gemini choice.
    private var effectiveModel: String {
        if provider.model.isEmpty, provider.provider == .gemini { return AIModelFamily.geminiDefault(availableModels) ?? "" }
        return provider.model
    }
    private var effectiveFamily: AIModelFamily? {
        let family = AIModelFamily.split(effectiveModel).family
        return modelFamilies.first { $0.id == family }
    }

    var modelChoices: [Choice] {
        let all = levelsInModel ? modelFamilies.map { Choice(id: $0.id, name: $0.name) } : availableModels.map { Choice(id: $0.id, name: $0.name) }
        guard fastInModel else { return all }
        // A Fast twin is chosen with the Fast switch instead of being listed twice.
        let ids = all.map(\.id)
        return all.filter { AIModelFamily.speedCounterpart(of: $0.id, fast: false, in: ids) == nil }
    }
    /// "" while the provider's default is in use.
    var modelChoice: String {
        guard !provider.model.isEmpty else { return "" }
        let id = levelsInModel ? AIModelFamily.split(provider.model).family : provider.model
        if fastInModel, let base = AIModelFamily.speedCounterpart(of: id, fast: false, in: speedIDs) { return base }
        return id
    }
    /// A saved or custom model the provider's list does not show, or not yet while it loads.
    var modelChoiceUnlisted: Bool { !modelChoice.isEmpty && !modelChoices.contains { $0.id == modelChoice } }
    var defaultModelLabel: String {
        switch provider.provider {
        case .opencode: return "Space Bunny (free, not kept)"
        case .ollama: return "First downloaded model"
        case .gemini: return "Gemini Flash, light thinking (fast)"
        case .openAIAPI, .anthropicAPI, .geminiAPI: return automaticAPIModel.map { "Automatic: \($0)" } ?? "Automatic, fast and low-cost"
        default: return "Current provider default"
        }
    }
    var modelLabel: String {
        guard provider.model.isEmpty else { return modelChoices.first { $0.id == modelChoice }?.name ?? provider.model }
        switch provider.provider {
        case .gemini: return effectiveFamily?.name ?? "Gemini Flash"
        case .opencode: return "Space Bunny"
        case .ollama: return availableModels.first?.name ?? "No model"
        case .openAIAPI, .anthropicAPI, .geminiAPI: return automaticAPIModel ?? "Automatic"
        default: return "Default model"
        }
    }
    /// The fast, low-cost model an API provider uses when none is chosen, once its list has loaded.
    private var automaticAPIModel: String? {
        ProviderAPI.automaticModel(provider.provider, from: availableModels.map(\.id)).map { id in
            availableModels.first { $0.id == id }?.name ?? id
        }
    }

    func chooseModel(_ id: String) {
        guard id != modelChoice else { return }
        // A model with a Fast twin keeps the speed already chosen.
        let speed = fastInModel && fastOn && !id.isEmpty ? AIModelFamily.speedCounterpart(of: id, fast: true, in: speedIDs) : nil
        if id.isEmpty { provider.model = "" }
        else if levelsInModel, let family = modelFamilies.first(where: { $0.id == (speed ?? id) }) {
            provider.model = family.model(keeping: AIModelFamily.split(effectiveModel).level)
        } else { provider.model = speed ?? id }
        providerChoiceChanged()
    }

    var thinkingChoices: [Choice] {
        if levelsInModel {
            guard let family = effectiveFamily, family.levels.count > 1 else { return [] }
            return family.levels.map { Choice(id: $0.level, name: AIModelFamily.label($0.level)) }
        }
        return thinkingLevels.map { Choice(id: $0, name: AIModelFamily.label($0)) }
    }
    var thinkingChoice: String {
        if levelsInModel { return AIModelFamily.split(effectiveModel).level }
        if let chosen = provider.reasoningEffort, thinkingLevels.contains(chosen) { return chosen }
        return thinkingLevels.contains("high") ? "high" : thinkingLevels.last ?? ""
    }

    func chooseThinking(_ level: String) {
        if levelsInModel {
            guard let model = effectiveFamily?.model(for: level) else { return }
            provider.model = model
        } else { provider.reasoningEffort = level }
        providerChoiceChanged()
    }

    // MARK: Context window

    private func windowName(_ tokens: Int) -> String { tokens.formatted(.number.notation(.compactName)) + " tokens" }
    var contextWindowChoices: [Choice] {
        guard let windows = contextWindows else { return [] }
        return windows.options.map { Choice(id: String($0), name: windowName($0) + ($0 == windows.standard ? " (default)" : "")) }
    }
    /// The window in use: a chosen one while it still applies to the model, else the default.
    var contextWindowChoice: String {
        guard let windows = contextWindows else { return "" }
        if let chosen = provider.contextWindow, chosen != windows.standard, windows.options.contains(chosen),
           provider.provider != .grok || !provider.model.isEmpty { return String(chosen) }
        return String(windows.standard)
    }

    func chooseContextWindow(_ id: String) {
        guard let windows = contextWindows, let tokens = Int(id), windows.options.contains(tokens), id != contextWindowChoice else { return }
        if tokens == windows.standard { provider.contextWindow = nil } else {
            // Grok applies a window only to a model named on its command line, so its default is named.
            if provider.provider == .grok, provider.model.isEmpty {
                guard let named = availableModels.first(where: \.isDefault)?.id else { return }
                provider.model = named
            }
            provider.contextWindow = tokens
        }
        providerChoiceChanged()
    }

    // MARK: Fast mode

    /// Grok and Cursor list Fast as its own model; Claude and Codex take it as a setting.
    private var fastInModel: Bool { [.grok, .cursor].contains(provider.provider) }
    /// What a Fast twin is looked up in: model families for Cursor, models for Grok.
    private var speedIDs: [String] { levelsInModel ? modelFamilies.map(\.id) : availableModels.map(\.id) }
    /// The listed model in use, Grok's own default included.
    private var speedModel: String {
        if provider.model.isEmpty, provider.provider == .grok { return availableModels.first { $0.isDefault }?.id ?? "" }
        return levelsInModel ? AIModelFamily.split(effectiveModel).family : effectiveModel
    }
    /// The model that is the chosen one at the other speed, for Grok and Cursor.
    private func speedSwitch(toFast fast: Bool) -> String? {
        guard fastInModel, !speedModel.isEmpty,
              let twin = AIModelFamily.speedCounterpart(of: speedModel, fast: fast, in: speedIDs) else { return nil }
        guard levelsInModel else { return twin }
        return modelFamilies.first { $0.id == twin }?.model(keeping: AIModelFamily.split(effectiveModel).level)
    }

    var fastOn: Bool { fastInModel ? speedModel.hasSuffix("-fast") : provider.fast == true && fastSettingNote != nil }
    var fastAvailable: Bool { fastInModel ? speedSwitch(toFast: !fastOn) != nil : fastSettingNote != nil }
    /// What the confirmation says before Fast mode is turned on.
    var fastWarning: String {
        if let fastSettingNote { return fastSettingNote }
        let twin = speedSwitch(toFast: true) ?? ""
        let name = availableModels.first { $0.id == twin }?.name ?? twin
        return "Switches to \(name). Fast models answer sooner and use your plan's limits faster."
    }

    func setFast(_ on: Bool) {
        guard on != fastOn, fastAvailable else { return }
        if fastInModel {
            guard let model = speedSwitch(toFast: on) else { return }
            provider.model = model
        } else { provider.fast = on ? true : nil }
        providerChoiceChanged()
    }

    private func providerChoiceChanged() {
        let config = provider
        Task {
            await saveSettings()
            let (levels, fastNote, windows) = await Task.detached { Self.modelSettings(config) }.value
            if config == provider { thinkingLevels = levels; fastSettingNote = fastNote; contextWindows = windows }
        }
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

    /// Signs Codex in with ChatGPT for OpenAI transcription, or installs Codex first.
    func signInToCodex() {
        guard let codex = ChatGPTSignIn.codexExecutable(configured: codexPath) else {
            guard let command = AIProviderKind.codex.installScript else { return }
            openTerminal(name: "Install", lines: "\(command)\nprintf '\\nWhen it finishes, return to Reprise. Press Return to close.\\n'", tool: "Codex")
            return
        }
        let path = "'" + codex.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        openTerminal(name: "Sign-In", lines: "unset OPENAI_API_KEY\n\(path) login\nprintf '\\nReturn to Reprise and choose Check. Press Return to close.\\n'", tool: "Codex")
    }

    /// Signs Antigravity in with Google for Gemini transcription, or installs it first.
    func signInToAntigravity() {
        let configuration = AIProviderConfiguration(provider: .gemini, executablePath: geminiPath)
        guard let command = ai.loginCommand(configuration: configuration) else {
            guard let script = AIProviderKind.gemini.installScript else { return }
            openTerminal(name: "Install", lines: "\(script)\nprintf '\\nWhen it finishes, return to Reprise and choose Check. Press Return to close.\\n'", tool: "Antigravity")
            return
        }
        let path = "'" + command.executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        openTerminal(name: "Sign-In", lines: "unset GEMINI_API_KEY\nprintf 'Sign in with Google when asked, then type /quit.\\n\\n'\n\(path)\nprintf '\\nReturn to Reprise and choose Check. Press Return to close.\\n'", tool: "Antigravity")
    }

    private func openTerminal(name: String, lines: String, tool: String? = nil) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Reprise-Login", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("\((tool ?? provider.provider.displayName).replacingOccurrences(of: " ", with: "-"))-\(name).command")
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

    /// Names no meeting content, like the summary notification.
    private func notify(_ title: String, _ body: String, momentID: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let momentID { content.userInfo = ["momentID": momentID] }
            center.add(UNNotificationRequest(identifier: "meeting-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    func openMemory(id: String) async {
        searchOnly = false
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

    /// Escape closes the search, and the next one starts fresh; a finished search stays under
    /// recent searches. A search that is still answering is kept so its answer is not lost.
    @discardableResult func dismissSearch() -> Bool {
        guard searchPresented else { return false }
        searchPresented = false
        if !asking { startNewSearch() }
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
                let imported = try await ImageImporter.shared.importFile(url, root: root, cipher: cipher)
                try await store.insert(imported.moment, textRead: imported.textRead)
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

    func shutdown() { heartbeat?.cancel(); askTask?.cancel(); scrubTask?.cancel(); archiveTask?.cancel(); rereadTask?.cancel(); meetingDetector.stop() }

    /// Work that quitting would cut short: a meeting, live captions or the assistant, an answer, a
    /// summary, an import or a model download.
    var hasWorkInProgress: Bool {
        func fetching(_ state: LocalSpeechModels.State) -> Bool {
            if case .downloading = state { return true }
            return state == .preparing
        }
        return meeting.isRecording || meeting.isBusy || captions.isRunning || assistant.isRunning || asking || busy
            || !summarizing.isEmpty || modelDownload != nil || speechModels.whisper.values.contains(where: fetching) || fetching(speechModels.speakers)
    }

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

    /// The share of a saved screen's height that shows its menu bar, on a screen where the menu bar
    /// takes `share` of the height. Screens saved before Reprise left the menu bar out show it;
    /// imported pictures never had one.
    func menuBarShare(of moment: Moment, screen share: Double) -> Double {
        Self.menuBarShare(of: moment, screen: share, since: store.screensWithoutMenuBarSince)
    }

    nonisolated static func menuBarShare(of moment: Moment, screen share: Double, since: Date?) -> Double {
        guard share > 0, let since, moment.timestamp < since, !(moment.appName == "Imported" && moment.bundleID.isEmpty) else { return 0 }
        return share
    }

    /// Reads the text of screens that have none yet, newest first, one at a time with a pause between
    /// them, waiting while on battery: screens saved while text recognition did not answer, and
    /// screens from before 0.8.1, which lost Korean text because recognition used English first.
    /// While recognition does not answer, reading waits; a screen it fails on is tried again at the
    /// next launch. With none left, it looks again every few minutes.
    private func startRereadingScreens() {
        rereadTask?.cancel()
        let store = self.store, root = self.root, cipher = self.cipher, languages = settings.ocrLanguages
        let menuBar = NSScreen.main.map { ($0.frame.maxY - $0.visibleFrame.maxY) / max(1, $0.frame.height) } ?? 0
        Task { screensToReread = (try? await store.screensNeedingTextCount()) ?? 0 }
        // Utility, not background: a background-priority Vision request beside a capture stalled both.
        rereadTask = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            // Capture's own lane, so this never runs Vision at the same time as a capture.
            let reader = CaptureImageProcessor.shared
            var movie: (path: String, frames: FrameReader)?
            var unreadable: Set<String> = []
            /// Nil when the screen's picture is gone.
            func text(of moment: Moment) async throws -> String? {
                var image: CGImage?
                if !moment.imagePath.isEmpty {
                    image = AppModel.still(root.appendingPathComponent(moment.imagePath), cipher: cipher)
                } else if let frame = moment.archivedFrame {
                    if movie?.path != frame.path { movie = (frame.path, FrameReader(movie: root.appendingPathComponent(frame.path), cipher: cipher)) }
                    image = try? await movie?.frames.image(at: frame.offset)
                }
                guard let image else { return nil }
                let share = AppModel.menuBarShare(of: moment, screen: menuBar, since: store.screensWithoutMenuBarSince)
                return try await reader.recognizeText(in: image, languages: languages, ignoringTopRows: Int((Double(image.height) * share).rounded()))
            }
            while !Task.isCancelled {
                if AppModel.onBattery() {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    continue
                }
                let batch = ((try? await store.screensNeedingText(limit: 20 + unreadable.count)) ?? []).filter { !unreadable.contains($0.id) }
                if batch.isEmpty {
                    await self?.setScreensToReread(0)
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    continue
                }
                for listed in batch {
                    guard !Task.isCancelled else { return }
                    let recognized: String?
                    do {
                        var read = try await text(of: listed)
                        // Archiving may have moved the still into a movie since the batch was read.
                        if read == nil, let current = try? await store.moment(id: listed.id), current != listed {
                            read = try await text(of: current)
                        }
                        recognized = read
                    } catch is CancellationError {
                        return
                    } catch {
                        // Recognition that does not answer is waited for; a screen that fails otherwise waits for the next launch.
                        if !(error is TextReadingLane.Failure) { unreadable.insert(listed.id) }
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        break
                    }
                    // A screen that cannot be saved would come back in every batch, so stop until next launch.
                    do { try await store.saveRecognizedText(id: listed.id, text: recognized) } catch { return }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
                let remaining = (try? await store.screensNeedingTextCount()) ?? 0
                await self?.setScreensToReread(remaining)
            }
        }
    }

    private func setScreensToReread(_ count: Int) { screensToReread = count }

    nonisolated static func still(_ url: URL, cipher: VaultCipher) -> CGImage? {
        guard let data = try? cipher.contents(of: url, maxBytes: 64 * 1024 * 1024),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated static func onBattery() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return source as String == kIOPSBatteryPowerValue
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
    /// A picture whose text cannot be read now is saved without it, and its text is read in the background.
    func importFile(_ url: URL, root: URL, cipher: VaultCipher) async throws -> (moment: Moment, textRead: Bool) {
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
        let text = try? await CaptureImageProcessor.shared.recognizeText(in: image, languages: ["en-US", "ko-KR"],
                                                                         textScaleLimit: max(image.width, image.height))
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (Moment(id: id, timestamp: attributes.contentModificationDate ?? Date(), appName: "Imported", windowTitle: url.lastPathComponent, text: text ?? "", imagePath: relative, thumbnailPath: relative, byteCount: size), text != nil)
    }
}
