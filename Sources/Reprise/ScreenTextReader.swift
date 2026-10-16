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

/// Signatures of a screen below the menu bar: one for each 32-pixel run of every pixel row, and
/// one for each 32-pixel square folded from those runs, so an area that scrolled can be matched
/// row by row.
struct TileGrid: Equatable, Sendable {
    static let size = 32
    let width: Int
    let height: Int
    /// The first pixel row covered; rows above it belong to the menu bar.
    let top: Int
    let columns: Int
    let rows: Int
    /// `runs[column * lines + line]`: the run of `size` pixels at `column` in pixel row `top + line`.
    let runs: [UInt64]
    let signatures: [UInt64]
    var lines: Int { height - top }

    init?(_ image: CGImage, pixels: Data, top: Int) {
        let bytesPerPixel = image.bitsPerPixel / 8
        guard image.bitsPerPixel % 8 == 0, bytesPerPixel > 0, image.width > 0, image.height > 0,
              image.bytesPerRow >= image.width * bytesPerPixel, pixels.count >= image.bytesPerRow * image.height else { return nil }
        width = image.width
        height = image.height
        self.top = min(max(0, top), image.height - 1)
        columns = (width + Self.size - 1) / Self.size
        rows = (height - self.top + Self.size - 1) / Self.size
        var runs = [UInt64](repeating: 0, count: columns * (height - self.top))
        let bytesPerRow = image.bytesPerRow, rowBytes = width * bytesPerPixel, segment = Self.size * bytesPerPixel
        let (first, last, columns) = (self.top, height, columns)
        pixels.withUnsafeBytes { raw in
            runs.withUnsafeMutableBufferPointer { runs in
                for y in first..<last {
                    let rowStart = y * bytesPerRow
                    for column in 0..<columns {
                        var offset = rowStart + column * segment
                        let end = min(offset + segment, rowStart + rowBytes)
                        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                        while offset + 8 <= end {
                            hash = Self.fold(hash, raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                            offset += 8
                        }
                        while offset < end {
                            hash = Self.fold(hash, UInt64(raw[offset]))
                            offset += 1
                        }
                        runs[column * (last - first) + y - first] = hash
                    }
                }
            }
        }
        self.runs = runs
        var signatures = [UInt64](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                signatures[row * columns + column] = Self.signature(runs, lines: last - first, column: column, row: row, shift: 0) ?? 0
            }
        }
        self.signatures = signatures
    }

    private static func fold(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        let mixed = (hash ^ value) &* 0x0000_0100_0000_01b3
        return mixed ^ (mixed >> 29)
    }

    /// The square at `column` and `row` folded from the runs `shift` pixel rows below it; nil
    /// where that reaches past the screen.
    private static func signature(_ runs: [UInt64], lines: Int, column: Int, row: Int, shift: Int) -> UInt64? {
        let first = row * size + shift, count = min(size, lines - row * size)
        guard first >= 0, first + count <= lines else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in first..<(first + count) { hash = fold(hash, runs[column * lines + line]) }
        return hash
    }

    /// Where this screen differs from `previous`, in pixels with the origin at the top left: one
    /// rectangle per group of changed tiles, with a tile of margin. Nil when the screens differ in size.
    func changes(since previous: TileGrid) -> [CGRect]? {
        guard comparable(with: previous) else { return nil }
        return regions(signatures.indices.map { signatures[$0] != previous.signatures[$0] })
    }

    /// The tiles of `region` that still differ once the earlier screen's content there is moved up
    /// by `shift` pixel rows, grouped as in `changes(since:)`.
    func changes(in region: CGRect, since previous: TileGrid, shift: Int) -> [CGRect] {
        guard comparable(with: previous) else { return [region] }
        var changed = [Bool](repeating: false, count: signatures.count)
        let columnRange = max(0, Int(region.minX) / Self.size)...min(columns - 1, max(0, Int(region.maxX) - 1) / Self.size)
        let rowRange = max(0, (Int(region.minY) - top) / Self.size)...min(rows - 1, max(0, Int(region.maxY) - 1 - top) / Self.size)
        for row in rowRange {
            for column in columnRange {
                let moved = Self.signature(previous.runs, lines: lines, column: column, row: row, shift: shift)
                changed[row * columns + column] = moved != signatures[row * columns + column]
            }
        }
        return regions(changed)
    }

    /// How many pixel rows the content of `region` moved up since `previous` (negative: down).
    /// Rows that appear once on each screen vote for the distance between them; rows of one colour
    /// or repeated rows match anywhere and do not vote. Nil when the content did not simply move.
    func shift(in region: CGRect, since previous: TileGrid) -> Int? {
        guard comparable(with: previous) else { return nil }
        let firstColumn = max(0, Int(region.minX) / Self.size), lastColumn = min(columns - 1, max(0, Int(region.maxX) - 1) / Self.size)
        let firstLine = max(0, Int(region.minY) - top), lastLine = min(lines - 1, Int(region.maxY) - top - 1)
        guard firstColumn <= lastColumn, lastLine - firstLine >= 2 * Self.size else { return nil }
        func once(_ runs: [UInt64], column: Int) -> [UInt64: Int] {
            var found: [UInt64: Int] = [:], repeated = Set<UInt64>()
            for line in firstLine...lastLine {
                let run = runs[column * lines + line]
                if found.updateValue(line, forKey: run) != nil { repeated.insert(run) }
            }
            for run in repeated { found[run] = nil }
            return found
        }
        var votes: [Int: Int] = [:], matched = 0
        for column in stride(from: firstColumn, through: lastColumn, by: max(1, (lastColumn - firstColumn + 1) / 12)) {
            let earlier = once(previous.runs, column: column)
            for (run, line) in once(runs, column: column) {
                guard let before = earlier[run] else { continue }
                matched += 1
                if before != line { votes[before - line, default: 0] += 1 }
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= 8, best.value * 2 >= matched else { return nil }
        return best.key
    }

    private func comparable(with previous: TileGrid) -> Bool {
        previous.width == width && previous.height == height && previous.top == top && previous.signatures.count == signatures.count
    }

    /// One rectangle per group of changed tiles, with a tile of margin. Tiles up to one tile apart
    /// belong to the same change, like the letters of a typed word.
    private func regions(_ changed: [Bool]) -> [CGRect] {
        var seen = [Bool](repeating: false, count: changed.count)
        var regions: [CGRect] = []
        for start in changed.indices where changed[start] && !seen[start] {
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

    /// The normalized box of pixels given with the origin at the top left.
    static func box(pixels: CGRect, of size: CGSize) -> CGRect {
        CGRect(x: pixels.minX / size.width, y: 1 - pixels.maxY / size.height, width: pixels.width / size.width, height: pixels.height / size.height)
    }

    /// The areas to read again for `changes`: each grows over every earlier line it touches, so a
    /// line is read whole, and areas that meet or nearly meet are joined, since every reading has a
    /// cost of its own. Nil when so much changed that reading the whole screen costs about the same.
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
                    for second in grown.indices where second > first && grown[first].insetBy(dx: -48, dy: -48).intersects(grown[second]) {
                        grown[first] = grown[first].union(grown[second]); grown.remove(at: second); joined = true
                        break search
                    }
                }
            }
            settled = grown == areas
            areas = grown
        }
        let covered = areas.reduce(0) { $0 + $1.width * $1.height }
        guard settled, areas.count <= 8, covered <= readable.width * readable.height * 0.4 else { return nil }
        return areas
    }

    /// A line Vision likely read in the wrong language. A vertical bar inside the line against a
    /// letter or digit is how the strokes of Korean and other wide scripts come out when a line
    /// full of Latin text is read as Latin; bars at either end of a sure line are box borders
    /// drawn in text, as in terminal apps. An unsure line counts with any bar, or with characters
    /// of a wide script the person does not read, since unsure plain text is common on screens.
    static func looksMisread(_ text: String, confidence: Float, reading scripts: Set<Script>) -> Bool {
        let inner = Array(text.trimmingCharacters(in: CharacterSet(charactersIn: "|│ ")))
        for index in inner.indices where inner[index] == "|" {
            for neighbor in [index - 1, index + 1] where inner.indices.contains(neighbor) {
                if inner[neighbor].isLetter || inner[neighbor].isNumber { return true }
            }
        }
        guard confidence < 0.5 else { return false }
        return text.contains("|") || count(text, in: Set([Script.hangul, .kana, .han]).subtracting(scripts)) > 0
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
