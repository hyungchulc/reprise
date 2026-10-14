import AppKit
import SwiftUI
import RepriseCore

struct MemoryExplorerView: View {
    @ObservedObject var model: AppModel
    var topInset: CGFloat = 40
    var cornerRadius: CGFloat = 0
    @State private var calendarOpen = false
    @State private var jumpDate = Date()
    private var searchExpanded: Bool {
        get { model.searchPresented }
        nonmutating set { model.searchPresented = newValue }
    }
    @State private var showText = false
    @State private var zoom: Double = 1
    @State private var playing = false
    @State private var deleteConfirmation = false
    @State private var searchFocused = false
    @StateObject private var audio = MemoryAudioPlayer()
    @State private var transcriptExpanded = true
    @State private var expandedAudioID: String?
    @State private var pan = CGSize.zero
    @GestureState private var dragPan = CGSize.zero
    @State private var resultHeight: CGFloat = 100
    @State private var openingGlow = false
    @State private var scrollExclusions: [CGRect] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private var hasQuery: Bool { !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var resultsVisible: Bool { searchExpanded && (hasQuery || !model.searchTurns.isEmpty || model.appFilter != nil || model.mode == "meetings") }
    private var expandedResults: Bool { resultsVisible || model.asking || model.response != nil || model.searchError != nil }
    private var showsHistory: Bool { !hasQuery && model.searchTurns.isEmpty && !model.asking && !model.searchHistory.queries.isEmpty }
    private var searchAnimation: Animation? { model.preferences.animateSearch && !reduceMotion ? .spring(response: 0.34, dampingFraction: 0.88) : nil }
    private var previousSearchTurns: [MemorySearchTurn] {
        model.asking || model.searchError != nil ? model.searchTurns : Array(model.searchTurns.dropLast())
    }
    private var latestSearchID: String {
        if model.asking { return "search-pending" }
        if model.searchError != nil { return "search-error" }
        return model.searchTurns.last?.id ?? "search-local"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { searchFocused = false; calendarOpen = false }
                memoryCanvas(size: geometry.size)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(.regularMaterial)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                        }
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.45), location: 0.4), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 210)
                }.allowsHitTesting(false)
                VStack {
                    topControls.excludesMemoryScrolling().padding(.horizontal, 18).padding(.top, topInset)
                    MeetingPrompt(model: model, detector: model.meetingDetector, recorder: model.meeting).excludesMemoryScrolling().padding(.top, 12)
                    Spacer()
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if let moment = model.selection, moment.kind == "meeting", !searchExpanded {
                        MemoryAudioPanel(moment: moment, audio: audio, recorder: model.meeting, transcriptExpanded: $transcriptExpanded,
                                         transcriptHeight: min(240, max(80, geometry.size.height - 450)),
                                         summary: model.summaries[moment.id], summarizing: model.summarizing.contains(moment.id),
                                         summaryError: model.summaryErrors[moment.id], providerName: model.provider.provider.displayName,
                                         onSummarize: { Task { await model.summarize(moment) } },
                                         onTranscribe: { Task { await model.transcribeSelected() } })
                            .frame(width: min(780, geometry.size.width - 48))
                            .excludesMemoryScrolling().padding(.bottom, 12)
                    }
                    bottomControls.excludesMemoryScrolling()
                    MemoryTimeRail(model: model, referenceDate: model.timelineDate ?? model.selection?.timestamp ?? jumpDate,
                        onOpenRecording: { id in expandedAudioID = id; transcriptExpanded = true; searchFocused = false })
                }
                if searchExpanded {
                    VStack(spacing: 10) {
                        if showsHistory { recentSearches.frame(height: 32) }
                        searchSurface(maxHeight: min(580, max(100, geometry.size.height - 340)))
                    }
                        .frame(width: min(expandedResults ? 680 : 540, geometry.size.width - 48))
                        .excludesMemoryScrolling()
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2 - (showsHistory ? 21 : 0))
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                if showText {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Screen Text").font(.headline); Spacer(); Button { showText = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
                        ScrollView { Text(model.selection?.text ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        Button("Copy Text", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.selection?.text ?? "", forType: .string) }
                    }.padding(18).frame(width: 360, height: min(500, geometry.size.height - 180)).modifier(GlassSurface())
                        .excludesMemoryScrolling()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 20)
                }
            }.coordinateSpace(name: "memoryExplorer")
                .background(MemoryTimelineScrollInput(excludedRects: scrollExclusions, onScroll: model.scrollTimeline))
                .onPreferenceChange(MemoryScrollExclusions.self) { scrollExclusions = $0 }
                .clipped().overlay {
                if model.preferences.edgeGlow != false && (model.asking || openingGlow) {
                    MemoryEdgeGlow(accent: model.preferences.accent, cornerRadius: cornerRadius)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .ignoresSafeArea().environment(\.timeZone, model.timeZone).repriseAppearance(model.preferences)
        .animation(searchAnimation, value: searchExpanded)
        .animation(searchAnimation, value: expandedResults)
        .animation(searchAnimation, value: min(resultHeight, 440))
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .alert("Reprise", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete this memory and its local media?", isPresented: $deleteConfirmation) {
            Button("Delete Memory", role: .destructive) { Task { await model.deleteSelected() } }
        }
        .onChange(of: model.selection?.id) { _, _ in
            pan = .zero; transcriptExpanded = true; showText = false
            if model.selection?.kind == "meeting" {
                playing = false
                if searchExpanded { expandedAudioID = model.selection?.id }
            }
            else { expandedAudioID = nil }
        }
        .onChange(of: searchExpanded) { _, expanded in
            if !expanded { searchFocused = false; audio.pause() }
        }
        .task(id: model.selection?.id) { await audio.load(moment: model.selection, root: model.root, cipher: model.cipher) }
        .onDisappear { audio.unload() }
        .onReceive(NotificationCenter.default.publisher(for: .repriseFocusSearch)) { _ in
            searchExpanded = true
            searchFocused = true
        }
        .onReceive(model.meeting.$transcribingMomentID.compactMap { $0 }) { id in
            if model.selection?.id == id { transcriptExpanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repriseOverlayHidden)) { _ in
            openingGlow = false
            searchFocused = false
            searchExpanded = false
            calendarOpen = false
            showText = false
            playing = false
            audio.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .repriseOverlayShown)) { _ in
            if model.selection == nil { jumpDate = Date() }
            guard model.preferences.edgeGlow != false else { return }
            openingGlow = true
        }
        .task(id: openingGlow) {
            guard openingGlow else { return }
            try? await Task.sleep(for: .seconds(1.8))
            openingGlow = false
        }
        .task(id: playing) {
            while playing && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(0.65)) } catch { return }
                guard let selected = model.selection, model.moments.first?.id != selected.id else { playing = false; return }
                model.step(-1)
            }
        }
    }

    private var topControls: some View {
        HStack {
            HStack(spacing: 8) {
                RepriseIcon(size: 22)
                Text("Reprise").fontWeight(.medium)
            }.repriseFont().padding(.horizontal, 10).padding(.vertical, 6).modifier(GlassSurface())
            Spacer()
            HStack(spacing: 14) {
                RecordingControls(model: model, capture: model.capture, meeting: model.meeting)
                Button { NotificationCenter.default.post(name: .repriseCloseMemory, object: nil) } label: { Image(systemName: "xmark") }.help("Close overlay")
                moreMenu
            }.buttonStyle(.plain).focusEffectDisabled().padding(.horizontal, 14).padding(.vertical, 10).modifier(GlassSurface())
        }
    }

    @ViewBuilder private func memoryCanvas(size: CGSize) -> some View {
        Color.clear
        if let moment = model.selection {
            if moment.kind == "meeting" {
                Color.clear
            } else {
                MemoryImage(screenOf: moment, root: model.root, cipher: model.cipher,
                            maxPixels: min(8192, Int((max(size.width, size.height) * displayScale * zoom).rounded(.up))),
                            keepsPreviousImage: true)
                    .frame(width: size.width * zoom, height: size.height * zoom)
                    .offset(x: pan.width + dragPan.width, y: pan.height + dragPan.height)
                    .frame(width: size.width, height: size.height).clipped()
                    .onTapGesture { searchFocused = false; if resultsVisible { searchExpanded = false } }
                    .gesture(DragGesture().updating($dragPan) { value, state, _ in if zoom > 1 { state = value.translation } }.onEnded { value in
                        guard zoom > 1 else { return }
                        pan.width = min(size.width * (zoom - 1) / 2, max(-size.width * (zoom - 1) / 2, pan.width + value.translation.width))
                        pan.height = min(size.height * (zoom - 1) / 2, max(-size.height * (zoom - 1) / 2, pan.height + value.translation.height))
                    })
            }
        }
    }

    private func searchSurface(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if expandedResults {
                MemorySearchResultsView(latestID: latestSearchID, hasHistory: !previousSearchTurns.isEmpty,
                                        maxHeight: maxHeight, contentHeight: $resultHeight) {
                    if !model.searchTurns.isEmpty {
                        HStack {
                            Text("Memory search").repriseFont(.heading).lineLimit(1)
                            Spacer()
                            if let date = model.restoredSearchDate {
                                Label("Saved", systemImage: "clock.arrow.circlepath").repriseFont(.caption).foregroundStyle(.secondary).help(date.formatted())
                            }
                            Button { model.startNewSearch(); expandedAudioID = nil; audio.pause(); searchFocused = true } label: {
                                Image(systemName: "square.and.pencil")
                            }.buttonStyle(.plain).help("New search").accessibilityLabel("New search")
                        }
                    }
                    ForEach(previousSearchTurns) { turn in
                        conversationTurn(turn)
                    }
                } latest: {
                    if !model.asking, model.searchError == nil, let turn = model.searchTurns.last {
                        conversationTurn(turn)
                    }
                    if model.asking {
                        if let question = model.pendingQuestion { Text(question).repriseFont(.heading).textSelection(.enabled) }
                        HStack { ProgressView().controlSize(.small); Text("Searching memories...").repriseFont(); Spacer(); Button { model.cancelAnswer() } label: { Image(systemName: "stop.fill") }.help("Cancel search") }
                    }
                    if let message = model.searchError {
                        Text(message).repriseFont().foregroundStyle(.red).textSelection(.enabled)
                        Button("Provider Settings", systemImage: "gearshape") { model.settingsPage = "AI & Models"; model.showSettings = true }
                    }
                    if let message = model.searchNotice { Text(message).repriseFont(.caption).foregroundStyle(.secondary) }
                    if !model.asking {
                        if let moment = model.selection, moment.kind == "meeting", expandedAudioID == moment.id,
                           !model.displayedMatches.contains(where: { $0.id == moment.id }) {
                            inlineAudio(moment)
                        }
                        if !model.displayedMatches.isEmpty {
                            Text(model.response == nil ? "\(model.displayedMatches.count) memories" : "\(model.displayedMatches.count) supporting memories").repriseFont(.caption).foregroundStyle(.secondary)
                            ForEach(model.displayedMatches.filter { $0.kind == "meeting" }) { moment in
                                if expandedAudioID == moment.id, model.selection?.id == moment.id {
                                    inlineAudio(model.selection ?? moment)
                                } else {
                                    Button {
                                        expandedAudioID = moment.id; transcriptExpanded = true; searchFocused = false
                                        Task { await model.openMatch(moment) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "waveform").font(.system(size: 24)).foregroundStyle(Color.accentColor).frame(width: 36)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(moment.windowTitle.isEmpty ? "Recording" : moment.windowTitle).repriseFont(.heading).lineLimit(1)
                                                Text(moment.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).repriseFont(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if let duration = moment.audioDuration { Text(MemoryAudioPanel.timestamp(duration)).monospacedDigit().repriseFont(.caption) }
                                            Image(systemName: "chevron.down").foregroundStyle(.secondary)
                                        }.padding(.vertical, 8).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Open recording: \(moment.windowTitle)")
                                }
                                Divider()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 14) {
                                ForEach(model.displayedMatches.filter { $0.kind != "meeting" }) { moment in
                                    Button {
                                        Task { await model.openMatch(moment) }
                                        searchFocused = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Group {
                                                if moment.kind == "meeting" { Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
                                                else { MemoryImage(path: moment.thumbnailPath, root: model.root, cipher: model.cipher, maxPixels: 480) }
                                            }.aspectRatio(1.6, contentMode: .fit).clipped()
                                                .overlay { RoundedRectangle(cornerRadius: 4).stroke(moment.id == model.selection?.id ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: moment.id == model.selection?.id ? 2 : 1) }
                                            Text(moment.windowTitle.isEmpty ? moment.appName : moment.windowTitle).repriseFont(.heading).lineLimit(1)
                                            HStack { Text(moment.appName).lineLimit(1); Spacer(); Text(moment.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).lineLimit(1) }.repriseFont(.caption).foregroundStyle(.secondary)
                                            if let citation = model.response?.citations.first(where: { $0.momentID == moment.id }) {
                                                Text(citation.label).repriseFont(.caption).foregroundStyle(Color.accentColor).lineLimit(2)
                                            }
                                        }
                                    }.buttonStyle(.plain).help("Open \(moment.appName) memory")
                                }
                            }
                        } else if hasQuery && model.response == nil && model.searchError == nil && model.searchNotice == nil { Text("No local text matches").repriseFont().foregroundStyle(.secondary) }
                    }
                }.transition(.opacity)
                Divider().padding(.horizontal, 16)
            }
            HStack(spacing: 12) {
                Image(systemName: model.searchTurns.isEmpty ? "magnifyingglass" : "bubble.left.and.text.bubble.right").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                MemorySearchField(text: $model.search, isFocused: $searchFocused,
                                  fontSize: model.preferences.textSize + 2, placeholder: model.searchTurns.isEmpty ? "Search your memory" : "Ask a follow-up", onSubmit: submitSearch)
                    .frame(height: model.preferences.textSize + 12)
                if hasQuery { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear input") }
                Button(action: submitSearch) { Image(systemName: "arrow.up") }.buttonStyle(.borderedProminent).disabled(!hasQuery || model.asking).help("Search with \(model.provider.provider.displayName)")
            }.padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 10)
            HStack(spacing: 15) {
                Menu {
                    Button("All Apps") { model.appFilter = nil }
                    ForEach(model.stats.apps, id: \.self) { app in Button(app) { model.appFilter = app } }
                } label: { Label(model.appFilter ?? "Apps", systemImage: "app.dashed") }.fixedSize()
                Toggle(isOn: Binding(get: { model.mode == "meetings" }, set: { model.mode = $0 ? "meetings" : "all" })) { Label("Audio", systemImage: "waveform") }.toggleStyle(.button)
                Spacer()
                Menu {
                    ForEach(AIProviderKind.allCases) { provider in Button(provider.displayName) { model.selectProvider(provider) } }
                    Divider()
                    Text(model.provider.model.isEmpty ? "Current provider default" : model.provider.model)
                    Button("Model Settings...") { model.settingsPage = "AI & Models"; model.showSettings = true }
                } label: { Label(model.provider.provider.displayName, systemImage: "sparkles") }.fixedSize()
                Button { searchExpanded = false; searchFocused = false } label: { Image(systemName: "chevron.down") }.help("Minimize search")
            }.repriseFont(.caption).buttonStyle(.borderless).padding(.horizontal, 16).padding(.bottom, 11)
        }.modifier(GlassSurface())
    }

    private func conversationTurn(_ turn: MemorySearchTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question).repriseFont(.heading).textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(turn.response.usage.provider.capitalized)
                Text(turn.response.usage.model).foregroundStyle(.secondary).lineLimit(1)
            }.repriseFont(.caption).foregroundStyle(Color.accentColor)
            if let coverage = turn.response.coverage {
                HStack(spacing: 4) {
                    Text(coverage.oldest, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Image(systemName: "arrow.right").font(.system(size: 9))
                    Text(coverage.newest, format: .dateTime.hour().minute())
                    Text("\(coverage.totalRecords) records · \(coverage.suppliedRecords) excerpts")
                }.repriseFont(.caption).foregroundStyle(.secondary)
                    .help("\(coverage.suppliedRecords) of \(coverage.activityCount) app, title and time groups. Excerpts are partial; unrecorded time is unknown.")
            }
            Text(linkedAnswer(turn.response)).repriseFont().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "reprise", let citation = turn.response.citations.first(where: { $0.momentID == url.lastPathComponent }) else { return .discarded }
                    Task {
                        await model.openCitation(citation.momentID)
                        if model.selection?.kind == "meeting" { expandedAudioID = model.selection?.id; transcriptExpanded = true }
                    }
                    return .handled
                })
        }
    }

    private func inlineAudio(_ moment: Moment) -> some View {
        MemoryAudioPanel(moment: moment, audio: audio, recorder: model.meeting, transcriptExpanded: $transcriptExpanded,
            transcriptHeight: 140, framed: false, summary: model.summaries[moment.id], summarizing: model.summarizing.contains(moment.id),
            summaryError: model.summaryErrors[moment.id], providerName: model.provider.provider.displayName,
            onSummarize: { Task { await model.summarize(moment) } }, onTranscribe: { Task { await model.transcribeSelected() } },
            onClose: { expandedAudioID = nil; audio.pause() })
            .task(id: moment.id) { await model.loadSummary(for: moment.id) }
    }

    private var recentSearches: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            ForEach(model.searchHistory.queries, id: \.self) { query in
                Button {
                    searchFocused = false
                    Task { await model.restoreSearch(query) }
                } label: {
                    Text(query).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160)
                }.buttonStyle(.plain).help(query).accessibilityLabel("Open saved search: \(query)")
            }
        }.repriseFont(.caption).padding(.horizontal, 12).padding(.vertical, 8).modifier(CapsuleGlassSurface())
    }

    private var bottomControls: some View {
        ZStack {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.skip(1) } label: { Image(systemName: "backward.end").frame(width: 26, height: 32) }.help("Back 30 seconds")
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 26, height: 32) }.help("Play memories").disabled(model.selection?.kind == "meeting")
                    Button { model.skip(-1) } label: { Image(systemName: "forward.end").frame(width: 26, height: 32) }.help("Forward 30 seconds")
                }.padding(.horizontal, 12).padding(.vertical, 4).modifier(GlassSurface())
                Spacer()
                HStack(spacing: 15) {
                    if let address = model.selection?.url, let url = URL(string: address) {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                            .help("Open \(BrowserAddress.short(address))").accessibilityLabel("Open page \(BrowserAddress.short(address))")
                    }
                    Button { searchExpanded.toggle(); searchFocused = searchExpanded } label: { Image(systemName: "magnifyingglass") }.help("Search memory")
                    Button {
                        if model.selection?.kind == "meeting" { searchExpanded = false; transcriptExpanded.toggle() }
                        else { showText.toggle() }
                    } label: { Image(systemName: model.selection?.kind == "meeting" ? "text.bubble" : "text.viewfinder") }
                        .help(model.selection?.kind == "meeting" ? "Transcript" : "Select screen text")
                    Button { zoom = zoom == 1 ? 1.5 : 1; pan = .zero } label: { Image(systemName: zoom == 1 ? "plus.magnifyingglass" : "minus.magnifyingglass") }.help("Zoom memory")
                    Button { Task { model.search = ""; model.dayFilter = nil; model.appFilter = nil; await model.reload() } } label: { Image(systemName: "arrow.right.to.line") }.help("Latest memory")
                }.padding(.horizontal, 16).padding(.vertical, 12).modifier(GlassSurface())
            }.padding(.horizontal, 18)
            Button { jumpDate = model.timelineDate ?? model.selection?.timestamp ?? Date(); calendarOpen = true } label: {
                HStack(spacing: 8) {
                    Text(model.timelineDate ?? model.selection?.timestamp ?? jumpDate, format: .dateTime.month(.abbreviated).day().hour().minute()).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.horizontal, 13).frame(height: 32)
            }.buttonStyle(.plain).modifier(CapsuleGlassSurface()).help("Date & Time").accessibilityLabel("Date & Time")
                .popover(isPresented: $calendarOpen, arrowEdge: .top) {
                CalendarPopover(date: $jumpDate, timeZone: model.timeZone, jump: { calendarOpen = false; Task { await model.jump(to: jumpDate) } }, availableDates: model.moments.map(\.timestamp))
            }
        }.buttonStyle(.plain).repriseFont(.caption).frame(height: 48)
    }

    private var moreMenu: some View {
        Menu {
            Button("Import Images...", systemImage: "square.and.arrow.down") { Task { await model.importImages() } }
            Button("Export Memories...", systemImage: "square.and.arrow.up") { Task { await model.exportLibrary() } }
            Button("Delete Memory...", systemImage: "trash", role: .destructive) { deleteConfirmation = true }.disabled(model.selection == nil)
            Divider()
            Button("Settings...", systemImage: "gearshape") { model.showSettings = true }
        } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden).help("More")
    }
    private func submitSearch() {
        searchFocused = false
        model.ask()
    }

    private func linkedAnswer(_ response: AIResponse) -> AttributedString {
        let text = NSMutableAttributedString(string: response.text)
        for citation in response.citations {
            guard let path = citation.momentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "reprise://memory/\(path)"),
                  let expression = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: "[\(citation.label)]")) else { continue }
            for match in expression.matches(in: response.text, range: NSRange(location: 0, length: text.length)) {
                text.addAttribute(.link, value: url, range: match.range)
            }
        }
        return AttributedString(text)
    }
}

extension Notification.Name { static let repriseFocusSearch = Notification.Name("RepriseFocusSearch") }

struct MeetingPrompt: View {
    @ObservedObject var model: AppModel
    @ObservedObject var detector: MeetingDetector
    @ObservedObject var recorder: MeetingRecorder
    var body: some View {
        if let candidate = detector.candidate, !recorder.isRecording, !recorder.isBusy {
            HStack(spacing: 12) {
                Image(systemName: "video.badge.waveform")
                VStack(alignment: .leading) { Text(candidate.appName).font(.caption).foregroundStyle(.secondary); Text(candidate.title).lineLimit(1) }
                Button("Record", systemImage: "record.circle") { Task { await model.toggleMeeting() } }.buttonStyle(.borderedProminent)
                Button { detector.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss meeting")
            }.padding(12).frame(maxWidth: 580).modifier(GlassSurface())
        }
    }
}
