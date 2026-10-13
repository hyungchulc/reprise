import AppKit
import SwiftUI
import RepriseCore

@MainActor
final class MCPSettingsModel: ObservableObject {
    @Published private(set) var access = MCPAccess()
    @Published private(set) var clients: [MCPClientKind: MCPClientState] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    let helper: URL
    private let root: URL
    private let installer: MCPClientInstaller

    init(root: URL) {
        self.root = root
        helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RepriseMCP")
        installer = MCPClientInstaller(helper: helper, vault: root)
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { access = try MCPAccess.load(root: root) }
        catch { message = "MCP settings could not be read. Access remains disabled."; access = MCPAccess() }
        for client in MCPClientKind.allCases { clients[client] = await installer.status(client) }
    }

    func setAccess(enabled: Bool? = nil, images: Bool? = nil) {
        var value = access
        if let enabled { value.enabled = enabled }
        if let images { value.allowImages = images }
        do { try value.save(root: root); access = value; message = nil }
        catch { message = "MCP settings could not be saved. No access change was applied." }
    }

    func install(_ client: MCPClientKind, remove: Bool = false) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await installer.setInstalled(!remove, for: client)
            clients[client] = await installer.status(client)
            message = remove ? "Configuration removed. Restart \(client.rawValue)." : "Configuration saved. Restart \(client.rawValue) to connect."
        } catch { message = error.localizedDescription }
    }

    func copyConfiguration() async {
        do {
            let text = try await installer.configuration()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            message = "Configuration copied. It contains this app and library's local paths."
        } catch { message = "Configuration could not be copied." }
    }

    func check() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { message = try await installer.checkConnection() }
        catch { message = error.localizedDescription }
    }
}

struct MCPSettings: View {
    @StateObject private var model: MCPSettingsModel
    @State private var confirmAccess = false
    @State private var confirmImages = false
    init(root: URL) { _model = StateObject(wrappedValue: MCPSettingsModel(root: root)) }

    var body: some View {
        Group {
            Section("Memory Access") {
                Toggle("Allow MCP access", isOn: Binding(get: { model.access.enabled }, set: {
                    if $0 { confirmAccess = true } else { model.setAccess(enabled: false) }
                }))
                Toggle("Share screenshots", isOn: Binding(get: { model.access.allowImages }, set: {
                    if $0 { confirmImages = true } else { model.setAccess(images: false) }
                })).disabled(!model.access.enabled)
                LabeledContent("Transport", value: "Local stdio")
                LabeledContent("Access", value: "Read-only, this library")
                Text("Connected clients can read screen text and meeting transcripts, and may send them to their AI provider. Turning access off blocks subsequent tool responses; it cannot recall data already shared.")
                    .repriseFont(.caption).foregroundStyle(.secondary)
            }
            Section("Clients") {
                ForEach(MCPClientKind.allCases) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(client.rawValue)
                            Text(model.clients[client]?.message ?? "Checking...").repriseFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.clients[client] == .installed {
                            Button("Remove", systemImage: "minus.circle") { Task { await model.install(client, remove: true) } }
                        } else {
                            Button("Install", systemImage: "plus.circle") { Task { await model.install(client) } }
                                .disabled(!model.access.enabled || model.clients[client] != .absent)
                        }
                    }.disabled(model.busy)
                }
            }
            Section("Connection") {
                HStack {
                    Button("Check Connection", systemImage: "checkmark.shield") { Task { await model.check() } }
                        .disabled(!model.access.enabled || model.busy)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.busy)
                }
                Button("Copy Configuration", systemImage: "doc.on.doc") { Task { await model.copyConfiguration() } }
                if model.busy { ProgressView().controlSize(.small) }
                if let message = model.message { Text(message).repriseFont(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("Allow connected AI clients to read this memory library?", isPresented: $confirmAccess) {
            Button("Allow Memory Access") { model.setAccess(enabled: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Screen text, titles, timestamps and meeting transcripts may leave this Mac through the client. Audio files are never provided. Only connect clients you trust.")
        }
        .confirmationDialog("Also allow screenshots to be shared?", isPresented: $confirmImages) {
            Button("Allow Screenshots") { model.setAccess(images: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Screenshots can contain private messages, account details and other sensitive information.") }
    }
}
