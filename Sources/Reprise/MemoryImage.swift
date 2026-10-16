import AppKit
import ImageIO
import RepriseCore
import SwiftUI

actor ImageCache {
    static let shared = ImageCache()
    private let previews = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var readers: [String: FrameReader] = [:]
    private var readerOrder: [String] = []
    init() {
        previews.totalCostLimit = 96 * 1024 * 1024; previews.countLimit = 4
        thumbnails.totalCostLimit = 8 * 1024 * 1024; thumbnails.countLimit = 100
    }
    /// `topCrop` is the share of the image's height cut from the top.
    func image(url: URL, cipher: VaultCipher, maxPixels: Int, topCrop: Double = 0) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let cache = maxPixels <= 512 ? thumbnails : previews
        let key = "\(url.absoluteString):\(maxPixels):\(topCrop)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let decoded: CGImage?
        if let frame = FrameArchive.frameReference(url) {
            decoded = try? await reader(frame.movie, cipher: cipher, maxPixels: maxPixels).image(at: frame.offset)
        } else if let data = try? cipher.contents(of: url, maxBytes: 64 * 1024 * 1024),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else { decoded = nil }
        guard var cgImage = decoded, !Task.isCancelled else { return nil }
        let rows = Int((Double(cgImage.height) * min(0.5, max(0, topCrop))).rounded())
        if rows > 0, let cropped = cgImage.cropping(to: CGRect(x: 0, y: rows, width: cgImage.width, height: cgImage.height - rows)) {
            cgImage = cropped
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// One decoder per recently viewed movie and size class, since scrubbing stays within a movie.
    private func reader(_ movie: URL, cipher: VaultCipher, maxPixels: Int) -> FrameReader {
        let limit = maxPixels <= 1024 ? 1024 : (maxPixels <= 2048 ? 2048 : 0)
        let key = "\(movie.path)|\(limit)"
        readerOrder.removeAll { $0 == key }
        readerOrder.append(key)
        if let reader = readers[key] { return reader }
        let reader = FrameReader(movie: movie, cipher: cipher, maxPixels: limit)
        readers[key] = reader
        if readerOrder.count > 6 { readers.removeValue(forKey: readerOrder.removeFirst()) }
        return reader
    }
}

/// Where a memory's full screen image lives: a still file, or a frame of an archive movie.
enum MemoryMedia: Hashable {
    case still(String)
    case frame(String, Double)
    init?(screenOf moment: Moment) {
        if !moment.imagePath.isEmpty { self = .still(moment.imagePath) }
        else if let frame = moment.archivedFrame { self = .frame(frame.path, frame.offset) }
        else { return nil }
    }
    var key: String {
        switch self { case .still(let path): return path; case .frame(let path, let offset): return "\(path)#\(offset)" }
    }
    func url(in root: URL) -> URL {
        switch self {
        case .still(let path): return root.appendingPathComponent(path)
        case .frame(let path, let offset): return FrameArchive.frameURL(movie: root.appendingPathComponent(path), offset: offset)
        }
    }
}

struct MemoryImage: View {
    let media: MemoryMedia?
    let root: URL
    let maxPixels: Int
    var keepsPreviousImage = false
    /// The share of the image's height left out at the top.
    var topCrop: Double = 0
    /// Fills the space beside a picture of another shape, once there is a picture.
    var backdrop: Color?
    @StateObject private var loader: MemoryImageLoader

    init(path: String, root: URL, cipher: VaultCipher, maxPixels: Int, keepsPreviousImage: Bool = false) {
        self.init(media: path.isEmpty ? nil : .still(path), root: root, cipher: cipher, maxPixels: maxPixels, keepsPreviousImage: keepsPreviousImage)
    }
    init(screenOf moment: Moment, root: URL, cipher: VaultCipher, maxPixels: Int, keepsPreviousImage: Bool = false,
         topCrop: Double = 0, backdrop: Color? = nil) {
        self.init(media: MemoryMedia(screenOf: moment), root: root, cipher: cipher, maxPixels: maxPixels, keepsPreviousImage: keepsPreviousImage,
                  topCrop: topCrop, backdrop: backdrop)
    }
    init(media: MemoryMedia?, root: URL, cipher: VaultCipher, maxPixels: Int, keepsPreviousImage: Bool, topCrop: Double = 0, backdrop: Color? = nil) {
        self.media = media; self.root = root; self.maxPixels = maxPixels; self.keepsPreviousImage = keepsPreviousImage
        self.topCrop = topCrop; self.backdrop = backdrop
        _loader = StateObject(wrappedValue: MemoryImageLoader(cipher: cipher))
    }

    private var key: String { "\(root.path):\(media?.key ?? ""):\(maxPixels):\(topCrop)" }
    var body: some View {
        Group {
            if let image = loader.image, keepsPreviousImage || loader.loadedKey == key {
                let picture = Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                if let backdrop { picture.frame(maxWidth: .infinity, maxHeight: .infinity).background(backdrop) } else { picture }
            }
            else if keepsPreviousImage { Color.clear }
            else { ZStack { Color(nsColor: .controlBackgroundColor); Image(systemName: media == nil ? "waveform" : "photo").foregroundStyle(.tertiary) } }
        }
        .transaction { $0.animation = nil }
        .onChange(of: key, initial: true) { _, _ in
            guard let media else { loader.clear(); return }
            loader.request(key: key, url: media.url(in: root), maxPixels: maxPixels, topCrop: topCrop, keepsPreviousImage: keepsPreviousImage)
        }
        .onDisappear { loader.cancel() }
    }
}

@MainActor
final class MemoryImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var loadedKey = ""
    private struct Request { let key: String; let url: URL; let maxPixels: Int; let topCrop: Double }
    private var latestKey = ""
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var keepsPreviousImage = false
    private let load: (URL, Int, Double) async -> NSImage?

    init(load: @escaping (URL, Int, Double) async -> NSImage?) { self.load = load }

    convenience init(cipher: VaultCipher) {
        self.init { url, size, topCrop in await ImageCache.shared.image(url: url, cipher: cipher, maxPixels: size, topCrop: topCrop) }
    }

    func request(key: String, url: URL, maxPixels: Int, topCrop: Double = 0, keepsPreviousImage: Bool) {
        self.keepsPreviousImage = keepsPreviousImage
        latestKey = key
        if loadedKey == key { pending = nil; return }
        pending = Request(key: key, url: url, maxPixels: maxPixels, topCrop: topCrop)
        guard worker == nil else { return }
        let generation = self.generation
        // Finish the frame already decoding, then jump to the latest request. Canceling
        // every frame starves the preview during continuous high-resolution scrolling.
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.worker = nil } }
            while let request = self.pending {
                self.pending = nil
                let loaded = await self.load(request.url, request.maxPixels, request.topCrop)
                guard !Task.isCancelled, generation == self.generation else { return }
                if let loaded, request.key == self.latestKey || (self.keepsPreviousImage && self.pending != nil) {
                    self.image = loaded
                    self.loadedKey = request.key
                }
            }
        }
    }

    func cancel() { worker?.cancel(); worker = nil; pending = nil; generation = UUID() }
    func clear() { cancel(); image = nil; loadedKey = ""; latestKey = "" }
}
