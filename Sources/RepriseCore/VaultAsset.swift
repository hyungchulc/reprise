import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A movie or recording in the library for AVFoundation. Sealed files are decrypted range by
/// range as the decoder asks for them, so no plaintext copy is ever written; files from before
/// encryption open directly.
public final class VaultAsset: @unchecked Sendable {
    public let asset: AVURLAsset
    private let loader: Loader?

    public init(url: URL, cipher: VaultCipher) throws {
        guard VaultCipher.isSealed(fileAt: url) else {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            asset = AVURLAsset(url: url); loader = nil; return
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .mpeg4Movie
        let loader = Loader(reader: try VaultCipher.Reader(url: url, cipher: cipher), contentType: type.identifier)
        var components = URLComponents()
        components.scheme = "reprise-vault"; components.host = "library"; components.path = "/" + url.lastPathComponent
        asset = AVURLAsset(url: components.url ?? URL(string: "reprise-vault://library/media")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        self.loader = loader
    }

    private final class Loader: NSObject, AVAssetResourceLoaderDelegate {
        let queue = DispatchQueue(label: "Reprise vault media")
        private let reader: VaultCipher.Reader
        private let contentType: String

        init(reader: VaultCipher.Reader, contentType: String) {
            self.reader = reader; self.contentType = contentType
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            if let information = request.contentInformationRequest {
                information.contentType = contentType
                information.contentLength = reader.length
                information.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                let end = data.requestsAllDataToEndOfResource ? reader.length : min(reader.length, data.requestedOffset + Int64(data.requestedLength))
                var offset = data.currentOffset
                do {
                    while offset < end, !request.isCancelled {
                        let piece = try reader.read(offset: offset, count: Int(min(Int64(VaultCipher.chunkSize), end - offset)))
                        guard !piece.isEmpty else { break }
                        data.respond(with: piece)
                        offset += Int64(piece.count)
                    }
                } catch {
                    request.finishLoading(with: error)
                    return true
                }
            }
            request.finishLoading()
            return true
        }
    }
}
