import AppKit
import Combine
import ServiceManagement
import Speech
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
                    case .mcp: MCPSettings(root: model.root)
                    }
                }.formStyle(.grouped).frame(maxWidth: .infinity)
            }
        }.frame(width: 780, height: 650).repriseAppearance(model.preferences)
        .background(SettingsWindowLayer())
        .task { metrics.start() }
        .onAppear { page = SettingsPage(rawValue: model.settingsPage) ?? .general }
        .onChange(of: page) { _, value in model.settingsPage = value?.rawValue ?? "General" }
        .onDisappear { metrics.stop(); Task { await model.saveSettings() } }
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
            Picker("Transcription language", selection: $model.preferences.speechLocale) {
                ForEach(SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted(), id: \.self) { identifier in
                    Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                }
            }.disabled(!model.preferences.transcribeMeetings)
            LabeledContent("Microphone", value: "System default input")
            LabeledContent("Recording limit", value: "4 hours")
        }
        Section("Meetings") {
            Toggle("Detect meeting windows", isOn: $model.preferences.detectMeetings)
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
            Stepper("Retention: \(model.settings.retentionDays) days", value: $model.settings.retentionDays, in: 1...365)
            HStack { Text("Limit"); Slider(value: $model.settings.storageLimitGB, in: 1...100, step: 1); Text("\(Int(model.settings.storageLimitGB)) GB").monospacedDigit().frame(width: 55) }
            Button("Apply Retention Now", systemImage: "trash", role: .destructive) { confirmCleanup = true }
            Button("Open Library Folder", systemImage: "folder") { NSWorkspace.shared.open(model.root) }
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
    private var selection: Binding<String> {
        Binding(get: {
            if customModel || (!model.provider.model.isEmpty && !model.availableModels.contains(where: { $0.id == model.provider.model })) { return "__custom" }
            return model.provider.model
        }, set: { value in
            customModel = value == "__custom"
            if !customModel { model.provider.model = value; Task { await model.saveSettings() } }
        })
    }
    var body: some View {
        Section("AI & Models") {
            Picker("Provider", selection: Binding(get: { model.provider.provider }, set: { model.selectProvider($0); customModel = false })) {
                ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Model", selection: selection) {
                Text("Current provider default").tag("")
                ForEach(model.availableModels) { Text($0.name).tag($0.id) }
                Text("Custom model...").tag("__custom")
            }
            if selection.wrappedValue == "__custom" { TextField("Model identifier", text: $model.provider.model).textFieldStyle(.roundedBorder) }
            LabeledContent("Account", value: model.accountStatus?.message ?? "Checking...")
            LabeledContent("Search", value: model.providerStatus?.canAnswer == true ? "Available" : (model.providerStatus?.message ?? "Checking..."))
            HStack {
                Button("Sign In", systemImage: "person.crop.circle") { model.signIn() }.disabled(model.providerStatus?.isInstalled != true)
                Spacer()
                if model.checkingProvider { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshStatus() } }.disabled(model.checkingProvider)
            }
            Text("AI search sends selected screen text and transcripts to this provider. Images and audio files stay on this Mac.").repriseFont(.caption).foregroundStyle(.secondary)
        }
        Section("CLI Connection") {
            TextField("Executable path", text: Binding(get: { model.provider.executablePath ?? "" }, set: { model.provider.executablePath = $0.isEmpty ? nil : $0 }))
            Stepper("Request timeout: \(Int(model.provider.timeoutSeconds)) s", value: $model.provider.timeoutSeconds, in: 15...180, step: 15)
        }
        .onDisappear { Task { await model.saveSettings() } }
    }
}

struct PermissionSettings: View {
    @ObservedObject var center: PermissionCenter
    var body: some View {
        ForEach(PermissionCenter.Kind.allCases) { kind in
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
