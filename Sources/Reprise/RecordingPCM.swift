import AVFoundation
import Foundation
import RepriseCore

/// A library recording decoded to mono 32-bit float samples straight from its sealed file, a piece
/// at a time, so even a four-hour meeting never sits in memory whole.
final class RecordingPCM: @unchecked Sendable {
    let duration: Double
    let sampleRate: Double
    private let media: VaultAsset
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: [Float] = []
    private var finished = false

    init(url: URL, cipher: VaultCipher, sampleRate: Double) async throws {
        media = try VaultAsset(url: url, cipher: cipher)
        guard let track = try await media.asset.loadTracks(withMediaType: .audio).first else { throw CaptureFailure("The recording has no audio track.") }
        duration = try await media.asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CaptureFailure("The recording has no playable audio.") }
        reader = try AVAssetReader(asset: media.asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CaptureFailure("The recording cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CaptureFailure("The recording cannot be decoded.") }
        self.sampleRate = sampleRate
    }

    func cancel() { reader.cancelReading() }

    /// Up to `count` samples; fewer only at the end, and none once the recording is read.
    func read(_ count: Int) throws -> [Float] {
        while pending.count < count, !finished {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? CaptureFailure("The recording could not be decoded.") }
                finished = true
                break
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw CaptureFailure("The recording could not be decoded.") }
            pending += samples
        }
        let taken = Array(pending.prefix(count))
        pending.removeFirst(taken.count)
        return taken
    }

    /// The recording in pieces of about `seconds`, each cut at the quietest moment near its end so
    /// no word is split. `body` gets each piece with its start in seconds.
    func pieces(of seconds: Double, _ body: (Double, [Float]) async throws -> Void) async throws {
        let target = Int(seconds * sampleRate), slack = Int(20 * sampleRate)
        var carry: [Float] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            carry += try read(target + slack - carry.count)
            guard !carry.isEmpty else { return }
            if carry.count < target + slack {
                try await body(Double(start) / sampleRate, carry)
                return
            }
            let cut = Self.quietest(carry, from: target - slack, to: target + slack, window: Int(0.2 * sampleRate))
            try await body(Double(start) / sampleRate, Array(carry[..<cut]))
            carry = Array(carry[cut...])
            start += cut
        }
    }

    /// Mono AAC at 32 kbps, for pieces sent online: an `.m4a` file, or raw AAC for an `.aac` name.
    /// Gemini hears audio at 16 kbps, so this loses nothing it would use.
    static func writeAAC(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = Int(sampleRate) * 10
        var position = 0
        while position < samples.count {
            let count = min(step, samples.count - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { throw CaptureFailure("The recording could not be prepared to send.") }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + position, count: count) }
            try file.write(from: buffer)
            position += count
        }
    }

    /// The start of the quietest `window` between the two positions.
    static func quietest(_ samples: [Float], from lower: Int, to upper: Int, window: Int) -> Int {
        let lower = max(0, lower), upper = min(samples.count - window, upper)
        guard upper > lower, window > 0 else { return min(samples.count, max(1, upper)) }
        var best = lower, bestEnergy = Float.infinity
        var position = lower
        while position <= upper {
            var energy: Float = 0
            for index in position..<(position + window) { energy += samples[index] * samples[index] }
            if energy < bestEnergy { bestEnergy = energy; best = position }
            position += window / 2
        }
        return best + window / 2
    }
}
