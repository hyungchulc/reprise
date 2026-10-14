import Foundation
import RepriseCore
import SpeakerKit
import WhisperKit

/// Speech models Reprise downloads from Hugging Face and runs on this Mac: Whisper for
/// transcription and a speaker model that tells voices apart. They live outside the library.
@MainActor
final class LocalSpeechModels: ObservableObject {
    enum State: Equatable {
        case absent
        case downloading(Double)
        /// Compiling for this Mac's Neural Engine after a download, once per model.
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var whisper: [String: State] = [:]
    @Published private(set) var speakers: State = .absent
    /// Bytes on disk per downloaded Whisper model, and for the speaker model under "speakers".
    @Published private(set) var sizes: [String: Int64] = [:]
    let directory: URL
    private var work: [String: Task<Void, Never>] = [:]
    private var loaded: (id: String, kit: WhisperKit)?
    private var speakerKit: SpeakerKit?

    init(directory: URL = ReprisePaths.defaultRoot.appendingPathComponent("Models", isDirectory: true)) {
        self.directory = directory
        refresh()
    }

    private var whisperBase: URL { directory.appendingPathComponent("whisper", isDirectory: true) }
    private var speakerBase: URL { directory.appendingPathComponent("speakers", isDirectory: true) }
    /// The folder a download reported, kept in its marker; the usual layout before that.
    private func whisperFolder(_ id: String) -> URL {
        if let data = try? Data(contentsOf: marker(id)), let path = String(data: data, encoding: .utf8), path.hasPrefix(whisperBase.path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return whisperBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(id)", isDirectory: true)
    }
    private func marker(_ name: String) -> URL { directory.appendingPathComponent(".\(name).ready") }

    func state(of id: String) -> State { whisper[id] ?? .absent }
    func isReady(_ id: String) -> Bool { state(of: id) == .ready }

    func refresh() {
        for model in WhisperModel.all where work[model.id] == nil {
            let ready = FileManager.default.fileExists(atPath: marker(model.id).path)
            whisper[model.id] = ready ? .ready : .absent
            sizes[model.id] = ready ? Self.size(of: whisperFolder(model.id)) : nil
        }
        if work["speakers"] == nil {
            let ready = FileManager.default.fileExists(atPath: marker("speakers").path)
            speakers = ready ? .ready : .absent
            sizes["speakers"] = ready ? Self.size(of: speakerBase) : nil
        }
    }

    /// Downloads a Whisper model, then loads it once so it is compiled for this Mac.
    func download(_ id: String) {
        guard work[id] == nil, !isReady(id) else { return }
        whisper[id] = .downloading(0)
        work[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: self.whisperBase, withIntermediateDirectories: true)
                let report: @Sendable (Progress) -> Void = { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = self?.whisper[id] { self?.whisper[id] = .downloading(fraction) }
                    }
                }
                let folder = try await WhisperKit.download(variant: id, downloadBase: self.whisperBase, progressCallback: report)
                try Task.checkCancellation()
                self.whisper[id] = .preparing
                let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: self.whisperBase,
                                                                verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
                await kit.unloadModels()
                try Data(folder.path.utf8).write(to: self.marker(id))
                self.whisper[id] = .ready
                self.sizes[id] = Self.size(of: self.whisperFolder(id))
            } catch is CancellationError {
                self.whisper[id] = .absent
            } catch {
                self.whisper[id] = .failed(error.localizedDescription)
            }
            self.work[id] = nil
        }
    }

    func cancel(_ id: String) {
        work[id]?.cancel(); work[id] = nil
        if id == "speakers" { speakers = .absent } else { whisper[id] = .absent }
    }

    func delete(_ id: String) {
        cancel(id)
        if loaded?.id == id { loaded = nil }
        let folder = whisperFolder(id)
        try? FileManager.default.removeItem(at: marker(id))
        try? FileManager.default.removeItem(at: folder)
        refresh()
    }

    /// The speaker model is small; it downloads when speaker labels are turned on.
    func downloadSpeakers() {
        guard work["speakers"] == nil, speakers != .ready else { return }
        speakers = .downloading(0)
        work["speakers"] = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: self.speakerBase, withIntermediateDirectories: true)
                let kit = try await SpeakerKit(PyannoteConfig(downloadBase: self.speakerBase.path, download: true, load: true, verbose: false, logLevel: .none))
                await kit.unloadModels()
                try Data().write(to: self.marker("speakers"))
                self.speakers = .ready
                self.sizes["speakers"] = Self.size(of: self.speakerBase)
            } catch is CancellationError {
                self.speakers = .absent
            } catch {
                self.speakers = .failed(error.localizedDescription)
            }
            self.work["speakers"] = nil
        }
    }

    func deleteSpeakers() {
        cancel("speakers")
        speakerKit = nil
        try? FileManager.default.removeItem(at: marker("speakers"))
        try? FileManager.default.removeItem(at: speakerBase)
        refresh()
    }

    /// A downloaded Whisper model, loaded. Only one stays in memory.
    func whisperKit(_ id: String) async throws -> WhisperKit {
        if let loaded, loaded.id == id { return loaded.kit }
        guard isReady(id) else { throw CaptureFailure("The \(WhisperModel.named(id)) model is not downloaded. Download it in Audio settings.") }
        loaded = nil
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: whisperFolder(id).path, tokenizerFolder: whisperBase,
                                                        verbose: false, logLevel: .none, load: true, download: false))
        loaded = (id, kit)
        return kit
    }

    func speakerModel() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        guard speakers == .ready else { throw CaptureFailure("The speaker model is not downloaded.") }
        let kit = try await SpeakerKit(PyannoteConfig(downloadBase: speakerBase.path, download: true, load: true, verbose: false, logLevel: .none))
        speakerKit = kit
        return kit
    }

    /// Frees model memory after a transcription; the next one loads again in seconds.
    func unload() async {
        if let kit = loaded?.kit { await kit.unloadModels() }
        loaded = nil
        if let speakerKit { await speakerKit.unloadModels() }
        speakerKit = nil
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

enum SpeakerLabelLimit { static let seconds = 2.0 * 60 * 60 }

/// Set once to stop work that checks it.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Whisper text as a transcript shows it.
enum WhisperText {
    /// Whisper marks sounds such as music or silence in brackets; those are not speech.
    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*"), ("♪", "♪")]
        if let first = trimmed.first, let last = trimmed.last, pairs.contains(where: { $0.0 == first && $0.1 == last }) { return "" }
        return trimmed
    }
}
