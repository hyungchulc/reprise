import AppKit
import ImageIO
import SwiftUI

actor ImageCache {
    static let shared = ImageCache()
    private let previews = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    init() {
        previews.totalCostLimit = 96 * 1024 * 1024; previews.countLimit = 4
        thumbnails.totalCostLimit = 8 * 1024 * 1024; thumbnails.countLimit = 100
    }
    func image(url: URL, maxPixels: Int) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let cache = maxPixels <= 512 ? thumbnails : previews
        let key = "\(url.path):\(maxPixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

struct MemoryImage: View {
    let path: String
    let root: URL
    let maxPixels: Int
    var keepsPreviousImage = false
    @StateObject private var loader = MemoryImageLoader()
    private var key: String { "\(root.path):\(path):\(maxPixels)" }
    var body: some View {
        Group {
            if let image = loader.image, keepsPreviousImage || loader.loadedKey == key { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else if keepsPreviousImage { Color.clear }
            else { ZStack { Color(nsColor: .controlBackgroundColor); Image(systemName: path.isEmpty ? "waveform" : "photo").foregroundStyle(.tertiary) } }
        }
        .transaction { $0.animation = nil }
        .onChange(of: key, initial: true) { _, _ in
            guard !path.isEmpty else { loader.clear(); return }
            loader.request(key: key, url: root.appendingPathComponent(path), maxPixels: maxPixels, keepsPreviousImage: keepsPreviousImage)
        }
        .onDisappear { loader.cancel() }
    }
}

@MainActor
final class MemoryImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var loadedKey = ""
    private struct Request { let key: String; let url: URL; let maxPixels: Int }
    private var latestKey = ""
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var keepsPreviousImage = false
    private let load: (URL, Int) async -> NSImage?

    init(load: @escaping (URL, Int) async -> NSImage?) { self.load = load }

    convenience init() {
        self.init { url, size in await ImageCache.shared.image(url: url, maxPixels: size) }
    }

    func request(key: String, url: URL, maxPixels: Int, keepsPreviousImage: Bool) {
        self.keepsPreviousImage = keepsPreviousImage
        latestKey = key
        if loadedKey == key { pending = nil; return }
        pending = Request(key: key, url: url, maxPixels: maxPixels)
        guard worker == nil else { return }
        let generation = self.generation
        // Finish the frame already decoding, then jump to the latest request. Canceling
        // every frame starves the preview during continuous high-resolution scrolling.
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.worker = nil } }
            while let request = self.pending {
                self.pending = nil
                let loaded = await self.load(request.url, request.maxPixels)
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
