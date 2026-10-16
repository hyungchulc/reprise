import CoreGraphics
import Foundation
import RepriseCore

/// One line of screen text and where it sits, in normalized coordinates of the whole screen with
/// the origin at the bottom left, as Vision gives them.
struct ScreenTextLine: Equatable, Sendable {
    var box: CGRect
    var text: String
}

/// What the last saved screen held: a signature of each tile of its pixels and the text read from
/// it. The next screen compares its tiles with these and reads again only where they differ.
struct ScreenReading: Sendable {
    let display: UInt32?
    let languages: [String]
    /// Nil for a pixel layout that cannot be split into tiles.
    let tiles: TileGrid?
    let lines: [ScreenTextLine]
    /// The areas read for this screen, in pixels with the origin at the top left; nil when it was read whole.
    let areas: [CGRect]?
}

/// A signature for each 32-pixel square of a screen below the menu bar.
struct TileGrid: Equatable, Sendable {
    static let size = 32
    let width: Int
    let height: Int
    /// The first pixel row covered; rows above it belong to the menu bar.
    let top: Int
    let columns: Int
    let rows: Int
    let signatures: [UInt64]

    init?(_ image: CGImage, pixels: Data, top: Int) {
        let bytesPerPixel = image.bitsPerPixel / 8
        guard image.bitsPerPixel % 8 == 0, bytesPerPixel > 0, image.width > 0, image.height > 0,
              image.bytesPerRow >= image.width * bytesPerPixel, pixels.count >= image.bytesPerRow * image.height else { return nil }
        width = image.width
        height = image.height
        self.top = min(max(0, top), image.height - 1)
        columns = (width + Self.size - 1) / Self.size
        rows = (height - self.top + Self.size - 1) / Self.size
        var signatures = [UInt64](repeating: 0xcbf2_9ce4_8422_2325, count: columns * rows)
        let bytesPerRow = image.bytesPerRow, rowBytes = width * bytesPerPixel, segment = Self.size * bytesPerPixel
        let (first, last, columns) = (self.top, height, columns)
        pixels.withUnsafeBytes { raw in
            signatures.withUnsafeMutableBufferPointer { tiles in
                for y in first..<last {
                    let rowStart = y * bytesPerRow, tileRow = (y - first) / Self.size * columns
                    for column in 0..<columns {
                        var offset = rowStart + column * segment
                        let end = min(offset + segment, rowStart + rowBytes)
                        var hash = tiles[tileRow + column]
                        while offset + 8 <= end {
                            hash = (hash ^ raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) &* 0x0000_0100_0000_01b3
                            hash ^= hash >> 29
                            offset += 8
                        }
                        while offset < end {
                            hash = (hash ^ UInt64(raw[offset])) &* 0x0000_0100_0000_01b3
                            offset += 1
                        }
                        tiles[tileRow + column] = hash
                    }
                }
            }
        }
        self.signatures = signatures
    }

    /// Where this screen differs from `previous`, in pixels with the origin at the top left: one
    /// rectangle per group of changed tiles, with a tile of margin. Nil when the screens differ in size.
    func changes(since previous: TileGrid) -> [CGRect]? {
        guard previous.width == width, previous.height == height, previous.top == top, previous.signatures.count == signatures.count else { return nil }
        let changed = signatures.indices.map { signatures[$0] != previous.signatures[$0] }
        var seen = [Bool](repeating: false, count: changed.count)
        var regions: [CGRect] = []
        for start in changed.indices where changed[start] && !seen[start] {
            // Tiles up to one tile apart belong to the same change, like the letters of a typed word.
            var stack = [start], low = (column: start % columns, row: start / columns), high = low
            seen[start] = true
            while let index = stack.popLast() {
                let column = index % columns, row = index / columns
                low = (min(low.column, column), min(low.row, row)); high = (max(high.column, column), max(high.row, row))
                for nextRow in max(0, row - 2)...min(rows - 1, row + 2) {
                    for nextColumn in max(0, column - 2)...min(columns - 1, column + 2) {
                        let next = nextRow * columns + nextColumn
                        if changed[next], !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            let left = max(0, low.column - 1) * Self.size, right = min(width, (high.column + 2) * Self.size)
            let upper = top + max(0, low.row - 1) * Self.size, lower = min(height, top + (high.row + 2) * Self.size)
            regions.append(CGRect(x: left, y: upper, width: right - left, height: lower - upper))
        }
        return regions
    }
}

/// Reading order, coordinates and the signs of a misread line.
enum ScreenText {
    enum Script { case hangul, kana, han }

    /// Lines top to bottom, and left to right within a row, one per line of text.
    static func text(_ lines: [ScreenTextLine]) -> String {
        var rows: [[ScreenTextLine]] = []
        for line in lines.sorted(by: { ($0.box.midY, -$0.box.minX) > ($1.box.midY, -$1.box.minX) }) {
            if let first = rows.last?.first, line.box.midY >= first.box.minY, line.box.midY <= first.box.maxY {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }.map(\.text).joined(separator: "\n")
    }

    /// A box Vision gave for `area` of an image, in normalized coordinates of the whole image.
    /// `area` is in pixels with the origin at the top left; Vision's origin is at the bottom left.
    static func box(_ normalized: CGRect, in area: CGRect, of size: CGSize) -> CGRect {
        CGRect(x: (area.minX + normalized.minX * area.width) / size.width,
               y: (size.height - area.maxY + normalized.minY * area.height) / size.height,
               width: normalized.width * area.width / size.width, height: normalized.height * area.height / size.height)
    }

    /// The pixels of a normalized box, with the origin at the top left.
    static func pixels(_ box: CGRect, of size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    /// The areas to read again for `changes`: each grows over every earlier line it touches, so a
    /// line is read whole, and areas that meet are joined. Nil when so much changed that reading
    /// the whole screen costs about the same.
    static func readingAreas(_ changes: [CGRect], previous: [ScreenTextLine], size: CGSize, readable: CGRect) -> [CGRect]? {
        let lines = previous.map { pixels($0.box, of: size) }
        var areas = changes.map { $0.intersection(readable) }.filter { !$0.isNull && !$0.isEmpty }
        var settled = false
        for _ in 0..<12 where !settled {
            var grown = areas.map { area in lines.reduce(area) { $1.intersects(area) ? $0.union($1) : $0 }.intersection(readable) }
            var joined = true
            while joined {
                joined = false
                search: for first in grown.indices {
                    for second in grown.indices where second > first && grown[first].intersects(grown[second]) {
                        grown[first] = grown[first].union(grown[second]); grown.remove(at: second); joined = true
                        break search
                    }
                }
            }
            settled = grown == areas
            areas = grown
        }
        let covered = areas.reduce(0) { $0 + $1.width * $1.height }
        guard settled, areas.count <= 6, covered <= readable.width * readable.height * 0.4 else { return nil }
        return areas
    }

    /// A line Vision likely read in the wrong language: it was unsure, or a vertical bar sits
    /// against a letter or digit, which is how the strokes of Korean and other wide scripts come
    /// out when a line full of Latin text is read as Latin.
    static func looksMisread(_ text: String, confidence: Float) -> Bool {
        if confidence < 0.5 { return true }
        let characters = Array(text)
        for index in characters.indices where characters[index] == "|" {
            for neighbor in [index - 1, index + 1] where characters.indices.contains(neighbor) {
                if characters[neighbor].isLetter || characters[neighbor].isNumber { return true }
            }
        }
        return false
    }

    /// The scripts a wide-script language is written in.
    static func scripts(of language: String) -> Set<Script> {
        switch String(language.prefix { $0 != "-" }).lowercased() {
        case "ko": [.hangul]
        case "ja": [.kana, .han]
        case "zh", "yue": [.han]
        default: []
        }
    }

    static func count(_ text: String, in scripts: Set<Script>) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            let script: Script? = switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF: .hangul
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: .kana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: .han
            default: nil
            }
            return total + (script.map(scripts.contains) == true ? 1 : 0)
        }
    }
}
