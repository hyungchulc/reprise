import AppKit

final class TimelineArtwork {
    let icon: NSImage
    let colors: [NSColor]
    init(icon: NSImage, colors: [NSColor]) { self.icon = icon; self.colors = colors }
}

actor TimelineArtworkCache {
    static let shared = TimelineArtworkCache()
    private let cache = NSCache<NSString, TimelineArtwork>()

    init() { cache.countLimit = 96; cache.totalCostLimit = 1024 * 1024 }

    func artwork(bundleID: String, kind: String) -> TimelineArtwork {
        let key = "\(bundleID):\(kind)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage
        if kind == "meeting" {
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting")!
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app", accessibilityDescription: "Application")!
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: NSSize(width: 32, height: 32))
        thumbnail.addRepresentation(bitmap)
        let result = TimelineArtwork(icon: thumbnail, colors: Self.palette(bitmap))
        cache.setObject(result, forKey: key, cost: 4096)
        return result
    }

    static func palette(_ bitmap: NSBitmapImageRep) -> [NSColor] {
        var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat, saturation: CGFloat)] = [:]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.75 else { continue }
                let key = Int(color.hueComponent * 12) * 12 + Int(color.saturationComponent * 2.99) * 4 + Int(color.brightnessComponent * 3.99)
                var bucket = buckets[key] ?? (0, 0, 0, 0, 0)
                bucket.count += 1; bucket.r += color.redComponent; bucket.g += color.greenComponent
                bucket.b += color.blueComponent; bucket.saturation += color.saturationComponent
                buckets[key] = bucket
            }
        }
        let ranked = buckets.values.sorted {
            Double($0.count) * (0.2 + Double($0.saturation) / Double($0.count)) >
            Double($1.count) * (0.2 + Double($1.saturation) / Double($1.count))
        }
        var colors: [NSColor] = []
        for bucket in ranked where bucket.count >= 6 {
            let count = CGFloat(bucket.count)
            let color = NSColor(srgbRed: bucket.r / count, green: bucket.g / count, blue: bucket.b / count, alpha: 1)
            if !colors.isEmpty && color.saturationComponent < 0.15 { continue }
            if colors.contains(where: { abs($0.redComponent - color.redComponent) + abs($0.greenComponent - color.greenComponent) + abs($0.blueComponent - color.blueComponent) < 0.55 }) { continue }
            colors.append(color)
            if colors.count == 3 { break }
        }
        return colors.isEmpty ? [.secondaryLabelColor] : colors
    }
}
