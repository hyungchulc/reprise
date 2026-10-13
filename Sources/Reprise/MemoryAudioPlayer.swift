import AVFoundation
import Combine
import Foundation
import RepriseCore

@MainActor
final class MemoryAudioPlayer: ObservableObject {
    @Published private(set) var duration = 0.0
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var generation = UUID()
    private var scrubbing = false
    private var resumeAfterScrub = false

    var canPlay: Bool { player != nil && error == nil && duration > 0 }

    func load(moment: Moment?, root: URL) async {
        unload()
        guard let moment, moment.kind == "meeting" else { return }
        guard let path = moment.videoPath, !path.isEmpty else { error = "This memory has no audio file."; return }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.isReadableFile(atPath: url.path) else {
            error = "The original audio file is unavailable."; return
        }
        let token = generation
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let asset = AVURLAsset(url: url)
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0, try await asset.load(.isPlayable),
                  !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.player = player
            duration = seconds
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.generation == token, !self.scrubbing, time.seconds.isFinite else { return }
                    self.position = min(self.duration, max(0, time.seconds))
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.isPlaying = false; self.position = self.duration
                }
            }
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.pause(); self.error = "The audio could not be played. The original file has been kept."
                }
            }
        } catch {
            if generation == token, !Task.isCancelled { self.error = "This audio file could not be opened. The original file has been kept." }
        }
    }

    func togglePlayback() {
        guard canPlay else { return }
        if isPlaying { pause() }
        else {
            if position >= duration - 0.05 { seek(to: 0) }
            player?.play(); isPlaying = true
        }
    }

    func pause() {
        player?.pause(); isPlaying = false; resumeAfterScrub = false
    }

    func seek(to seconds: Double) {
        guard canPlay, seconds.isFinite else { return }
        position = min(duration, max(0, seconds))
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to seconds: Double) {
        guard seconds.isFinite else { return }
        position = min(duration, max(0, seconds))
    }

    func setScrubbing(_ editing: Bool) {
        if editing {
            resumeAfterScrub = isPlaying; player?.pause(); isPlaying = false; scrubbing = true
        } else {
            seek(to: position); scrubbing = false
            if resumeAfterScrub { player?.play(); isPlaying = true }
            resumeAfterScrub = false
        }
    }

    func unload() {
        generation = UUID()
        pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
        timeObserver = nil; endObserver = nil; statusObserver = nil
        player?.replaceCurrentItem(with: nil); player = nil
        duration = 0; position = 0; error = nil; isLoading = false; scrubbing = false
    }

    deinit {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
    }
}
