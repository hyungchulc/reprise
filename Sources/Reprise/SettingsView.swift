import AppKit
import Combine
import ServiceManagement
import SwiftUI
import RepriseCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", screen = "Screen Recording", audio = "Audio & Meetings"
    case privacy = "Privacy", models = "AI & Models", storage = "Storage", usage = "Usage & Performance"
    case mcp = "MCP & Integrations"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"; case .appearance: "paintpalette"; case .screen: "record.circle"
        case .audio: "waveform"; case .privacy: "hand.raised"; case .models: "sparkles"
        case .storage: "internaldrive"; case .usage: "chart.bar"
        case .mcp: "puzzlepiece.extension"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var metrics = ProcessMetrics()
    @Environment(\.dismiss) private var dismiss
    @State private var page: SettingsPage? = .general
    @State private var confirmCleanup = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var showRecoveryKey = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RepriseIcon(size: 32)
                Text("Settings").repriseFont(.title)
                Spacer()
                Button("Done") {
                    model.showSettings = false
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                List(SettingsPage.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                    .listStyle(.sidebar).frame(width: 188)
                Form {
                    switch page ?? .general {
                    case .general: general
                    case .appearance: AppearanceSettings(model: model)
                    case .screen: screen
                    case .audio: audio
                    case .privacy: privacy
                    case .models: AISettings(model: model)
                    case .storage: storage
                    case .usage: usage
                    case .mcp: MCPSettings(root: model.root, keys: model.keys)
                    }
                }.formStyle(.grouped).frame(maxWidth: .infinity)
            }
        }.frame(width: 780, height: 650).repriseAppearance(model.preferences)
        .background(SettingsWindowLayer())
        .task { metrics.start() }
        .onAppear { page = SettingsPage(rawValue: model.settingsPage) ?? .general }
        .onChange(of: page) { _, value in model.settingsPage = value?.rawValue ?? "General" }
        .onDisappear { metrics.stop(); Task { await model.saveSettings() } }
        .sheet(isPresented: $showRecoveryKey) { RecoveryKeyView(model: model) }
        .confirmationDialog("Permanently remove memories outside retention and storage limits?", isPresented: $confirmCleanup) {
            Button("Apply Retention", role: .destructive) { Task { await model.cleanLibrary() } }
        }
    }

    @ViewBuilder private var general: some View {
        Section("General") {
            Picker("Show Reprise in", selection: $model.preferences.iconPlacement) {
                ForEach(IconPlacement.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Open memory on launch", isOn: $model.preferences.showOnLaunch)
            Toggle("Start screen recording on launch", isOn: $model.preferences.startRecordingOnLaunch)
            Toggle("Remind me when recording is paused", isOn: Binding(get: { model.preferences.pauseReminders != false }, set: { model.preferences.pauseReminders = $0 }))
            Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, value in
                do {
                    if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginError = SMAppService.mainApp.status == .requiresApproval ? "Approval is required in System Settings > Login Items." : nil
                } catch { loginError = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
            }
            if let loginError { Text(loginError).foregroundStyle(.secondary).repriseFont(.caption) }
            ShortcutSettings(shortcut: model.shortcut)
            ShortcutSettings(shortcut: model.searchOnlyShortcut, title: "Search Only")
            Text("Opens just the search box, without the memory view behind it. Opening a memory from it shows the full view.")
                .foregroundStyle(.secondary).repriseFont(.caption)
            Button("Review Setup", systemImage: "checklist") { dismiss(); model.showOnboarding = true }
        }
        Section("Reprise") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
            Button("Open Library Folder", systemImage: "folder") { NSWorkspace.shared.open(model.root) }
        }
        UpdateSettings(updater: model.updater)
    }

    private var screen: some View {
        Section("Screen Recording") {
            Picker("Resolution", selection: $model.settings.maxDimension) {
                Text("Native (Retina)").tag(0)
                Text("1280 px").tag(1280); Text("1600 px").tag(1600); Text("2400 px").tag(2400); Text("3200 px").tag(3200); Text("3840 px").tag(3840)
            }
            HStack { Text("Interval"); Slider(value: $model.settings.interval, in: 1...30, step: 1); Text("\(Int(model.settings.interval)) s").monospacedDigit().frame(width: 45) }
            HStack { Text("Image quality"); Slider(value: $model.settings.imageQuality, in: 0.3...1, step: 0.05); Text(model.settings.imageQuality, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 45) }
            Picker("Text recognition", selection: Binding(get: { model.settings.ocrLanguages.joined(separator: ",") }, set: { model.settings.ocrLanguages = $0.components(separatedBy: ",") })) {
                Text("English & Korean").tag("en-US,ko-KR"); Text("English").tag("en-US"); Text("Korean").tag("ko-KR"); Text("Swedish & English").tag("sv-SE,en-US")
            }
            if model.screensToReread > 0 {
                Text("Reading text again in \(model.screensToReread) earlier screens. Versions before 0.8.1 missed Korean text. This runs slowly in the background and waits while on battery.")
                    .repriseFont(.caption).foregroundStyle(.secondary)
            }
            Toggle("Skip unchanged screens", isOn: $model.settings.deduplicate)
            Toggle("Pause on battery", isOn: $model.settings.pauseOnBattery)
            LabeledContent("Pause when idle", value: "5 minutes")
            CaptureCounters(capture: model.capture)
        }
    }

    @ViewBuilder private var audio: some View {
        Section("Audio") {
            Toggle("Include system audio", isOn: $model.preferences.includeSystemAudio)
            Toggle("Automatically transcribe after recording", isOn: $model.preferences.transcribeMeetings)
            LabeledContent("Microphone", value: "System default input")
            LabeledContent("Recording limit", value: "4 hours")
        }
        Section("Transcription Languages") {
            TranscriptionLanguageSettings(model: model, languages: model.speechLanguages)
        }
        Section("Meetings") {
            Toggle("Detect meeting windows", isOn: $model.preferences.detectMeetings)
            Toggle("Summarize meetings automatically", isOn: $model.preferences.summarizeMeetings)
            Text("After transcription, \(model.provider.provider.displayName) writes key points, decisions and action items, and a notification says when they are ready. Open the recording to read them.")
                .repriseFont(.caption).foregroundStyle(.secondary)
            MeetingStatus(model: model, detector: model.meetingDetector, recorder: model.meeting)
        }
    }

    @ViewBuilder private var privacy: some View {
        Section("Permissions") { PermissionSettings(center: model.permissions) }
        Section("Excluded Applications") {
            TextEditor(text: Binding(get: { model.settings.excludedBundleIDs.joined(separator: "\n") }, set: { model.settings.excludedBundleIDs = $0.split(separator: "\n").map(String.init) }))
                .font(.system(size: model.preferences.textSize, design: .monospaced)).frame(height: 90).accessibilityLabel("Excluded application bundle IDs")
            Menu("Exclude Running App") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? "Application") { if let id = app.bundleIdentifier, !model.settings.excludedBundleIDs.contains(id) { model.settings.excludedBundleIDs.append(id) } }
                }
            }
        }
        Section("Browser Addresses") {
            Toggle("Record the address of the current tab", isOn: $model.settings.recordBrowserAddresses)
            Text("Safari, Chrome, Arc, Edge, Brave and Vivaldi. macOS asks once per browser. Incognito windows are skipped, and sign-in tokens and other secret-looking parts are removed from addresses.")
                .repriseFont(.caption).foregroundStyle(.secondary)
        }
        Section("Private Window Titles") {
            TextEditor(text: Binding(get: { model.settings.excludedTitleTerms.joined(separator: "\n") }, set: { model.settings.excludedTitleTerms = $0.split(separator: "\n").map(String.init) }))
                .frame(height: 70).accessibilityLabel("Private window title patterns")
            Text("Detection depends on the window titles exposed by each app.").repriseFont(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var storage: some View {
        Section("Storage") {
            LabeledContent("Vault") { Text(model.root.path).textSelection(.enabled).lineLimit(3) }
            LabeledContent("Memories", value: model.stats.momentCount.formatted())
            if let oldest = model.stats.oldest { LabeledContent("Oldest memory") { Text(oldest, format: .dateTime.year().month().day().hour().minute()) } }
            LabeledContent("Recorded media", value: ByteCountFormatter.string(fromByteCount: model.stats.storedBytes, countStyle: .file))
            LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: model.stats.databaseBytes, countStyle: .file))
            if model.stats.archivedFrames > 0 { LabeledContent("Compressed screens", value: model.stats.archivedFrames.formatted()) }
            Stepper("Retention: \(model.settings.retentionDays) days", value: $model.settings.retentionDays, in: 1...365)
            HStack { Text("Limit"); Slider(value: $model.settings.storageLimitGB, in: 1...100, step: 1); Text("\(Int(model.settings.storageLimitGB)) GB").monospacedDigit().frame(width: 55) }
            Button("Apply Retention Now", systemImage: "trash", role: .destructive) { confirmCleanup = true }
            Button("Open Library Folder", systemImage: "folder") { NSWorkspace.shared.open(model.root) }
        }
        Section("Encryption") {
            LabeledContent("Library", value: "Encrypted, AES-256")
            LabeledContent("Key", value: "Login keychain, “Reprise Vault Key”")
            Text("Screen text, transcripts, screenshots and recordings are stored encrypted. Only Reprise and its MCP helper can use the key without asking. If another app asks for “Reprise Vault Key”, deny it unless you started that request.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = model.encryptionStatus { Text(status).font(.caption).foregroundStyle(.orange) }
            Button("Recovery Key...", systemImage: "key") { showRecoveryKey = true }
            Text("If this Mac's keychain loses the key, such as on a new Mac, the recovery key opens the library again. Keep it in a password manager.")
                .repriseFont(.caption).foregroundStyle(.secondary)
        }
        Section("Compression") {
            Toggle("Compress older screens", isOn: $model.settings.archiveOlderFrames)
            Picker("Compressed quality", selection: $model.settings.archiveQuality) {
                Text("Smaller").tag(0.5); Text("Balanced").tag(FrameArchive.balancedQuality); Text("Sharper").tag(0.8)
            }.disabled(!model.settings.archiveOlderFrames)
            Toggle("Halve the resolution of old screens", isOn: $model.settings.compactOlderFrames)
            Stepper("After \(model.settings.compactAfterDays) days", value: $model.settings.compactAfterDays, in: 1...90)
                .disabled(!model.settings.compactOlderFrames)
            Text("Screens older than 15 minutes are stored as HEVC video, about a sixth of the size. After the chosen number of days, that video is re-encoded at half resolution, so small text gets harder to read while search stays the same. Search text, thumbnails and bookmarked screens are unchanged. Deleted screens are removed from the video too.")
                .repriseFont(.caption).foregroundStyle(.secondary)
            if let status = model.archiveStatus { Text(status).repriseFont(.caption).foregroundStyle(.orange) }
        }
        Section("Import & Export") {
            Button("Import Images...", systemImage: "square.and.arrow.down") { Task { await model.importImages() } }
            Button("Export Memories...", systemImage: "square.and.arrow.up") { Task { await model.exportLibrary() } }
        }
    }

    @ViewBuilder private var usage: some View {
        Section("AI Usage, Last 30 Days") {
            LabeledContent("Requests", value: model.usages.count.formatted())
            LabeledContent("Reported input tokens", value: tokenTotal(model.usages.compactMap(\.inputTokens)))
            LabeledContent("Reported output tokens", value: tokenTotal(model.usages.compactMap(\.outputTokens)))
            LabeledContent("Subscription remaining", value: "Unavailable in Reprise")
            ForEach(model.usages.prefix(12)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(entry.provider.capitalized).fontWeight(.medium); Spacer(); Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                    HStack { Text(entry.model.isEmpty ? "Provider default" : entry.model).lineLimit(1); Spacer(); Text("\(entry.inputTokens.map(String.init) ?? "?") in / \(entry.outputTokens.map(String.init) ?? "?") out").monospacedDigit() }.repriseFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Live Process") {
            LabeledContent("Memory", value: ByteCountFormatter.string(fromByteCount: Int64(metrics.resident), countStyle: .memory))
            LabeledContent("CPU", value: String(format: "%.1f%%", metrics.cpu))
            LabeledContent("GPU", value: "Not measured")
            LabeledContent("Image cache limit", value: "96 MB previews + 8 MB thumbnails")
            LabeledContent("Memories", value: model.stats.momentCount.formatted())
        }
    }
    private func tokenTotal(_ values: [Int]) -> String { values.isEmpty ? "Not reported" : values.reduce(0, +).formatted() }
}

private struct SettingsWindowLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> LayerView { LayerView() }
    func updateNSView(_ view: LayerView, context: Context) {}
    final class LayerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        }
    }
}

struct AppearanceSettings: View {
    @ObservedObject var model: AppModel
    private let colors: [Color] = [.blue, .teal, .green, .yellow, .orange, .red, .pink, .purple, .gray]
    var body: some View {
        Section("Appearance") {
            Toggle("Follow system appearance", isOn: $model.preferences.followSystemAppearance)
            Toggle("Dark mode", isOn: $model.preferences.darkMode).disabled(model.preferences.followSystemAppearance)
            Toggle("Follow system accent color", isOn: $model.preferences.followSystemAccent)
            HStack(spacing: 10) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Button { model.preferences.setAccent(color) } label: {
                        Circle().fill(color).frame(width: 20, height: 20)
                            .overlay { Circle().strokeBorder(.primary.opacity(NSColor(color).isEqual(NSColor(model.preferences.accent)) ? 0.8 : 0.12), lineWidth: 2) }
                    }.buttonStyle(.plain).help(["Blue", "Teal", "Green", "Yellow", "Orange", "Red", "Pink", "Purple", "Gray"][index])
                }
                ColorPicker("Custom", selection: Binding(get: { model.preferences.accent }, set: { model.preferences.setAccent($0) }), supportsOpacity: false).labelsHidden()
            }.disabled(model.preferences.followSystemAccent)
            Stepper("Text size: \(Int(model.preferences.textSize)) pt", value: $model.preferences.textSize, in: 12...16)
            Toggle("Animate search transitions", isOn: $model.preferences.animateSearch)
            Toggle("Screen edge glow", isOn: Binding(get: { model.preferences.edgeGlow != false }, set: { model.preferences.edgeGlow = $0 }))
        }
    }
}

struct AISettings: View {
    @ObservedObject var model: AppModel
    @State private var customModel = false
    @State private var downloadName = Ollama.suggestedModels[0].id
    private var kind: AIProviderKind { model.provider.provider }
    private var selection: Binding<String> {
        // The model list loads after the sign-in check, so a saved model stays a choice of its own
        // until then; the identifier field opens only when Custom model is picked.
        Binding(get: { customModel ? "__custom" : model.modelChoice }, set: { value in
            customModel = value == "__custom"
            if !customModel { model.chooseModel(value) }
        })
    }
    private var installed: Bool { model.providerStatus?.isInstalled == true }
    var body: some View {
        Section("AI & Models") {
            Picker("Provider", selection: Binding(get: { kind }, set: { model.selectProvider($0); customModel = false })) {
                ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            Text(Self.about(kind)).repriseFont(.caption).foregroundStyle(.secondary)
            if kind != .apple {
                Picker("Model", selection: selection) {
                    Text(model.defaultModelLabel).tag("")
                    ForEach(model.modelChoices) { Text($0.name).tag($0.id) }
                    if model.modelChoiceUnlisted { Text(model.modelLabel).tag(model.modelChoice) }
                    Text("Custom model...").tag("__custom")
                }
                if customModel { TextField("Model identifier", text: $model.provider.model).textFieldStyle(.roundedBorder) }
                if !model.thinkingChoices.isEmpty {
                    Picker("Thinking", selection: Binding(get: { model.thinkingChoice }, set: { model.chooseThinking($0) })) {
                        ForEach(model.thinkingChoices) { Text($0.name).tag($0.id) }
                    }
                }
                if !model.contextWindowChoices.isEmpty {
                    Picker("Context window", selection: Binding(get: { model.contextWindowChoice }, set: { model.chooseContextWindow($0) })) {
                        ForEach(model.contextWindowChoices) { Text($0.name).tag($0.id) }
                    }
                    Text((kind == .claude ? "Claude Code works within this window and compacts at its edge; the model itself holds 1M. " : "How much the model can hold at once. ")
                         + "A search sends only a few thousand tokens and Reprise never compacts a conversation, so the choice mostly changes the ring's scale.")
                        .repriseFont(.caption).foregroundStyle(.secondary)
                }
                if model.fastAvailable {
                    FastModeSwitch(model: model)
                    Text(model.fastSettingNote ?? "Uses the model's Fast version, which answers sooner and uses your plan's limits faster.")
                        .repriseFont(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Account", value: model.accountStatus?.message ?? "Checking...")
            LabeledContent("Search", value: model.providerStatus?.canAnswer == true ? "Available" : (model.providerStatus?.message ?? "Checking..."))
            HStack {
                if model.providerStatus != nil && !installed {
                    Button(kind == .apple ? "Open Apple Intelligence Settings" : "Install \(kind.displayName)", systemImage: kind == .apple ? "gearshape" : "arrow.down.circle") { model.installProvider() }
                } else if kind.hasSignIn {
                    Button("Sign In", systemImage: "person.crop.circle") { model.signIn() }.disabled(!installed)
                } else if kind == .ollama && model.accountStatus?.signedIn == false {
                    Button("Start Ollama", systemImage: "play.circle") { model.startOllama() }
                }
                Spacer()
                if model.checkingProvider { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshStatus() } }.disabled(model.checkingProvider)
            }
            if model.providerStatus != nil && !installed, kind != .apple {
                Text("Install opens Terminal and runs \(kind.displayName)'s own installer, so you can see each step. Choose Refresh when it finishes.")
                    .repriseFont(.caption).foregroundStyle(.secondary)
            }
        }
        if kind == .ollama && model.accountStatus?.signedIn == true {
            Section("Ollama Models") {
                Picker("Download", selection: $downloadName) {
                    ForEach(Ollama.suggestedModels, id: \.id) { Text($0.name).tag($0.id) }
                }.disabled(model.modelDownload != nil)
                HStack {
                    TextField("Or another model name", text: $downloadName).textFieldStyle(.roundedBorder).disabled(model.modelDownload != nil)
                    Button("Download", systemImage: "arrow.down.circle") { model.downloadModel(downloadName) }
                        .disabled(model.modelDownload != nil || model.availableModels.contains { $0.id == downloadName })
                }
                if let download = model.modelDownload {
                    if let fraction = download.fraction { ProgressView(value: fraction) { Text("\(download.name): \(download.status)").repriseFont(.caption) } }
                    else { HStack { ProgressView().controlSize(.small); Text("\(download.name): \(download.status)").repriseFont(.caption) } }
                }
                Text("Models run in this Mac's memory. On a 16 GB Mac, models up to about 4 GB leave room for other apps.")
                    .repriseFont(.caption).foregroundStyle(.secondary)
            }
        }
        Section("CLI Connection") {
            if kind.commandName != nil && kind != .ollama {
                TextField("Executable path", text: Binding(get: { model.provider.executablePath ?? "" }, set: { model.provider.executablePath = $0.isEmpty ? nil : $0 }))
            }
            Stepper("Request timeout: \(Int(model.provider.timeoutSeconds)) s", value: $model.provider.timeoutSeconds, in: 15...180, step: 15)
        }
        .onDisappear { Task { await model.saveSettings() } }
    }

    static func about(_ kind: AIProviderKind) -> String {
        switch kind {
        case .apple: "Apple's model runs on this Mac and nothing leaves it. It reads about 4,000 tokens at once, so answers draw on fewer memories."
        case .ollama: "Runs a downloaded model on this Mac with Ollama, and nothing leaves it. Speed depends on the model and this Mac's memory."
        case .opencode: "Free OpenCode Zen models with no sign-in. Searched text goes to the model's provider; models marked \"not kept\" keep nothing, others may use it for training."
        case .gemini: "Uses your Google account through Antigravity CLI, which replaced Gemini CLI. Searched screen text and transcripts are sent to Google. Google has suspended accounts that used their sign-in in third-party tools; Reprise runs Google's own CLI and never reads the sign-in, but the risk is not zero."
        case .cursor: "Uses your Cursor subscription. Searched screen text and transcripts are sent to Cursor and the model you choose."
        default: "Uses your \(kind.displayName) subscription through its CLI. Searched screen text and transcripts are sent to the provider; images and audio stay on this Mac."
        }
    }
}

struct PermissionSettings: View {
    @ObservedObject var center: PermissionCenter
    var body: some View {
        // SpeechAnalyzer transcribes without the Speech Recognition permission.
        ForEach(PermissionCenter.Kind.allCases.filter { $0 != .speech || !SpeechLanguages.usesSpeechAnalyzer }) { kind in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName)
                    Text(center.status(for: kind).displayName).repriseFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if center.requesting == kind { ProgressView().controlSize(.small) }
                else if center.status(for: kind) == .authorized { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else {
                    Button(center.status(for: kind) == .denied || center.status(for: kind) == .restricted ? "Open Settings" : "Allow") {
                        if center.status(for: kind) == .denied || center.status(for: kind) == .restricted { center.openSettings(kind) }
                        else { Task { await center.request(kind) } }
                    }.disabled(center.requesting != nil)
                }
                Button { center.openSettings(kind) } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("\(kind.displayName) in System Settings")
            }
        }
        if let message = center.lastError { Text(message).repriseFont(.caption).foregroundStyle(.secondary) }
        Button("Refresh Permissions", systemImage: "arrow.clockwise") { center.refresh() }
        if center.screenAccessNeedsRefresh {
            Text("After approval, restart Reprise. If access is still unavailable, remove the old Reprise entry in System Settings and add this copy again.")
                .repriseFont(.caption).foregroundStyle(.secondary)
            Button("Show This App in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            Button("Restart Reprise", systemImage: "arrow.clockwise.circle") {
                NotificationCenter.default.post(name: .repriseRestart, object: nil)
            }
        }
    }
}

struct MeetingStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject var detector: MeetingDetector
    @ObservedObject var recorder: MeetingRecorder
    var body: some View {
        LabeledContent("Status", value: recorder.status)
        if let candidate = detector.candidate { LabeledContent("Detected", value: candidate.title) }
        if let message = recorder.lastError { Text(message).repriseFont(.caption).foregroundStyle(.secondary) }
        Button(recorder.isRecording ? "Stop and Save" : "Record Meeting", systemImage: recorder.isRecording ? "stop.circle" : "mic") { Task { await model.toggleMeeting() } }.disabled(recorder.isBusy)
    }
}

struct CaptureCounters: View {
    @ObservedObject var capture: CaptureEngine
    var body: some View {
        LabeledContent("Recorded this session", value: "\(capture.capturedCount)")
        LabeledContent("Skipped this session", value: "\(capture.skippedCount)")
        LabeledContent("Status", value: capture.status)
    }
}

@MainActor
final class ProcessMetrics: ObservableObject {
    @Published var resident: UInt64 = 0
    @Published var cpu: Double = 0
    private var task: Task<Void, Never>?
    private var lastTime = Date()
    private var lastCPU = 0.0
    func start() {
        sample()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.sample()
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    private func sample() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { resident = info.resident_size }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = Date(); let elapsed = now.timeIntervalSince(lastTime)
        if lastCPU > 0 && elapsed > 0 { cpu = max(0, (seconds - lastCPU) / elapsed * 100) }
        lastCPU = seconds; lastTime = now
    }
}

struct TranscriptionLanguageSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var languages: SpeechLanguages
    private var selection: [String] { model.preferences.speechLocales }
    var body: some View {
        ForEach(selection, id: \.self) { id in
            HStack {
                Text(languages.name(for: id))
                Spacer()
                state(languages.states[id])
                Button { model.preferences.speechLocales.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove \(languages.name(for: id))").disabled(selection.count == 1)
            }
        }
        Menu("Add Language") {
            ForEach(languages.options.filter { !selection.contains($0.id) }) { option in
                Button(option.name) { model.preferences.speechLocales.append(option.id) }
            }
        }.disabled(selection.count >= SpeechLanguageSelection.maximum || languages.options.isEmpty)
        Text(SpeechLanguages.usesSpeechAnalyzer
             ? "Each meeting is transcribed on this Mac in every chosen language, and each part keeps the language that fits it. Speech models download automatically, up to \(SpeechLanguageSelection.maximum) languages."
             : "Each meeting is transcribed in every chosen language, and each part keeps the language that fits it. Add on-device models in System Settings > Keyboard > Dictation.")
            .repriseFont(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func state(_ value: SpeechLanguages.State?) -> some View {
        switch value {
        case .installed: Label("Ready", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green).help("Installed on this Mac")
        case .downloading(let fraction): ProgressView(value: fraction).frame(width: 60).help("Downloading")
        case .needsDownload: Text(SpeechLanguages.usesSpeechAnalyzer ? "Waiting to download" : "Needs Dictation model").repriseFont(.caption).foregroundStyle(.secondary)
        case .unavailable: Text("Not available").repriseFont(.caption).foregroundStyle(.secondary)
        case .failed(let message): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
        case .checking, nil: ProgressView().controlSize(.small)
        }
    }
}
