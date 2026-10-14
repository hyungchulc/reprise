import AppKit
import RepriseCore
import SwiftUI

/// Shows the library's recovery key after the Mac's owner authenticates, for a password manager
/// or a file. Copies are marked concealed so clipboard managers skip them, and cleared after 90 s.
struct RecoveryKeyView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    @State private var failure: String?
    @State private var working = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(Color.accentColor)
                Text("Recovery Key").repriseFont(.title)
            }
            Text("Your library is encrypted with a key kept in this Mac's login keychain. If the keychain loses it, such as on a new Mac or after a keychain reset, this recovery key opens the library again.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Anyone with this key and a copy of your library can read every memory. Keep it in a password manager rather than in a note or email.")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if let key {
                Text(key).font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(key) }
                    Button("Save as File...", systemImage: "square.and.arrow.down") { save(key) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Button("Show Recovery Key", systemImage: "lock.open") { reveal() }.disabled(working)
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            if let failure { Text(failure).repriseFont(.caption).foregroundStyle(.red) }
            Text("To use it: when Reprise cannot find its key as it opens, choose Enter Recovery Key and paste this key.")
                .repriseFont(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 540).repriseAppearance(model.preferences)
    }

    private func reveal() {
        working = true; failure = nil
        Task {
            defer { working = false }
            do { key = try await model.revealRecoveryKey() }
            catch { failure = error.localizedDescription }
        }
    }

    private func copy(_ key: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(key, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = pasteboard.changeCount
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(90))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }

    private func save(_ key: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Reprise Recovery Key.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
            Reprise recovery key
            Library: \(model.root.path)
            Saved: \(Date().formatted(date: .long, time: .shortened))

            \(key)

            If Reprise cannot find its key in the login keychain, open Reprise, choose Enter Recovery Key and paste this key.
            Anyone with this key and a copy of the library can read it. After saving the key in a password manager, delete this file.

            """
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { failure = error.localizedDescription }
    }
}
