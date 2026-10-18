//
//  ChordGlyphs.swift
//  SolaPraise
//
//  The strip of chord symbols above a staff, read glyph by glyph: the ink
//  cut into tokens, each token's parts told apart by their SHAPE — a ♯, a
//  ♭, a raised small digit, the letters — and only the letters handed to
//  the text recogniser.
//
//  WHY: Vision is a text engine, and a chart's ♯ is a music glyph. Handed
//  「F♯m」 whole it answers 「Fim」 or 「Fm」; 「E/G♯」 becomes 「E/GF」;
//  「C♯7」, with its small raised 7, comes back as nothing at all; 「C9」
//  with a raised 9 as 「C°」. Every string repair written for one of these
//  left the next chart's spelling unrepaired. A ♯ is two uprights and two
//  bars, a ♭ an upright with a bowl, a superscript a small glyph whose
//  foot is above the baseline — all of which the ink says outright. So
//  the glyphs that are not letters are recognised here from their ink,
//  the letters alone go to Vision, and the chord is put back together by
//  position (Tools/bench-score-ocr.swift measures it on real charts).
//
//  The unit everywhere is the staff-line spacing, as in any OMR system:
//  it says how big a chord's letters are before one has been read.
//

import Foundation
import CoreGraphics
import ImageIO
import Vision

enum ChordGlyphs {

    /// One blob of ink, in the strip's pixel coordinates.
    struct Component {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var pixels: Int
        /// Every inked pixel, as an index into the strip, `stripWidth` wide.
        var points: [Int] = []
        var stripWidth: Int = 1
        /// Column by column, how many pixels of the blob are inked.
        var columns: [Int]
        /// Row by row.
        var rows: [Int]

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var midX: CGFloat { CGFloat(minX + maxX) / 2 }
    }

    enum Kind: Equatable { case sharp, flat, superscript, paren, noise, body }

    final class Part {
        let component: Component
        let kind: Kind
        init(component: Component, kind: Kind) { self.component = component; self.kind = kind }
    }

    /// A chord read: its text and its box in the strip, in pixels.
    struct Reading {
        let text: String
        let box: CGRect
        let confidence: Float
    }

    // MARK: - Ink

    /// Connected blobs of ink (4-connected) in a grey strip.
    static func components(_ gray: [UInt8], width: Int, height: Int, threshold: UInt8) -> [Component] {
        var label = [Int32](repeating: 0, count: width * height)
        var out: [Component] = []
        var stack: [Int] = []
        for start in 0..<(width * height) where gray[start] < threshold && label[start] == 0 {
            let id = Int32(out.count + 1)
            var c = Component(minX: width, minY: height, maxX: 0, maxY: 0, pixels: 0, stripWidth: width,
                              columns: [Int](repeating: 0, count: width), rows: [Int](repeating: 0, count: height))
            stack = [start]
            label[start] = id
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
                c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                c.pixels += 1
                c.points.append(p)
                c.columns[x] += 1; c.rows[y] += 1
                if x > 0, label[p - 1] == 0, gray[p - 1] < threshold { label[p - 1] = id; stack.append(p - 1) }
                if x + 1 < width, label[p + 1] == 0, gray[p + 1] < threshold { label[p + 1] = id; stack.append(p + 1) }
                if y > 0, label[p - width] == 0, gray[p - width] < threshold { label[p - width] = id; stack.append(p - width) }
                if y + 1 < height, label[p + width] == 0, gray[p + width] < threshold { label[p + width] = id; stack.append(p + width) }
            }
            // Trimmed to the blob's own extent.
            c.columns = Array(c.columns[c.minX...c.maxX])
            c.rows = Array(c.rows[c.minY...c.maxY])
            out.append(c)
        }
        return out
    }

    /// The page's ink threshold: between the paper and the print. Otsu's
    /// split of the grey histogram, kept a little towards the paper so a
    /// thin grey staff line still counts as ink.
    static func threshold(_ gray: [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for g in gray { hist[Int(g)] += 1 }
        let total = gray.count
        var sumAll = 0
        for (g, n) in hist.enumerated() { sumAll += g * n }
        var sumB = 0, weightB = 0, best = 0.0, split = 128
        for t in 0..<256 {
            weightB += hist[t]
            guard weightB > 0 else { continue }
            let weightF = total - weightB
            guard weightF > 0 else { break }
            sumB += t * hist[t]
            let meanB = Double(sumB) / Double(weightB), meanF = Double(sumAll - sumB) / Double(weightF)
            let between = Double(weightB) * Double(weightF) * (meanB - meanF) * (meanB - meanF)
            if between > best { best = between; split = t }
        }
        return UInt8(min(220, split + 30))
    }

    // MARK: - Tokens

    /// Blobs grouped into chord symbols: neighbours on the same row with
    /// less than a letter's gap between them. `unit` is the staff spacing.
    static func tokens(_ components: [Component], unit: CGFloat) -> [[Component]] {
        let sorted = components.sorted { $0.minX < $1.minX }
        var groups: [[Component]] = []
        for c in sorted {
            // The nearest group within reach on the same row — not only
            // the last begun: a speck above the line between two glyphs
            // must not part them.
            var best: (index: Int, gap: CGFloat)?
            for (index, group) in groups.enumerated() {
                let tail = group.max(by: { $0.maxX < $1.maxX })!
                let gap = CGFloat(c.minX - tail.maxX)
                let top = group.map(\.minY).min()!, bottom = group.map(\.maxY).max()!
                let overlaps = c.maxY >= top - Int(unit) && c.minY <= bottom + Int(unit)
                // Less than half a letter's height apart: one symbol; a
                // shorter glyph — the m7 of 「B m7」 set with a space —
                // from a little further.
                let tall = CGFloat(max(c.height, tail.height))
                let shorter = CGFloat(c.height) < CGFloat(tail.height) * 0.85
                guard overlaps, gap < max(unit * 0.55, tall * (shorter ? 0.85 : 0.65)) else { continue }
                let shared = CGFloat(min(c.maxY, bottom) - max(c.minY, top)) / CGFloat(c.height)
                let score = shared * 100 - max(0, gap)
                if best == nil || score > best!.gap { best = (index, score) }
            }
            if let best { groups[best.index].append(c) } else { groups.append([c]) }
        }
        return groups
    }

    /// What each blob of a token is, by its shape.
    ///
    /// The capital height and the baseline come from the letter-like
    /// blobs — those at least half as wide as they are tall — so a
    /// bracket, a ♭ or a descending j does not stretch the token and
    /// make every other glyph look raised.
    static func parts(_ token: [Component]) -> [Part] {
        guard !token.isEmpty else { return [] }
        func lettered(_ cs: [Component]) -> [Component] {
            cs.filter { CGFloat($0.width) >= CGFloat($0.height) * 0.45 && $0.pixels > 3 }
        }
        // First the accidentals, by shape alone: a ♯ stands taller than
        // the capitals and would otherwise set their height.
        var kinds = [Kind?](repeating: nil, count: token.count)
        for (i, c) in token.enumerated() {
            // Against the other glyphs' height: a ♯ stands taller than the
            // capitals, and judged by its own height it would be a letter.
            let others = lettered(token.indices.filter { $0 != i }.map { token[$0] }).map(\.height).max()
            let provisional = max(4, CGFloat(others ?? c.height))
            if isSharp(c, capHeight: provisional) { kinds[i] = .sharp }
            else if isFlat(c, capHeight: provisional) { kinds[i] = .flat }
        }
        var provisional: CGFloat = 4
        let rest = token.indices.filter { kinds[$0] == nil }.map { token[$0] }
        let letters = lettered(rest).isEmpty ? (rest.isEmpty ? token : rest) : lettered(rest)
        provisional = max(4, CGFloat(letters.map(\.height).max()!))
        let capHeight = provisional
        let feet = letters.filter { CGFloat($0.height) >= capHeight * 0.7 }.map(\.maxY).sorted()
        let baseline = feet.isEmpty ? token.map(\.maxY).max()! : feet[feet.count / 2]
        let capTop = CGFloat(baseline) - capHeight

        return token.enumerated().map { i, c in
            if let kind = kinds[i] { return Part(component: c, kind: kind) }
            let h = CGFloat(c.height), w = CGFloat(c.width)
            // A flat wide stroke — a tie's end, an underline — a thin
            // upright — a volta bracket's end — or a speck.
            if (h < capHeight * 0.3 && w > h * 2) || (h < capHeight * 0.45 && w > h * 2.5)
                || (w <= max(2, capHeight * 0.12) && h > capHeight * 0.5)
                || CGFloat(c.pixels) < capHeight * capHeight * 0.05 {
                return Part(component: c, kind: .noise)
            }
            // A small glyph with its foot above the baseline, or hung from
            // the capitals' top line as a chart's 「C9」 sets its 9: a
            // superscript. The letters of 「sus」 sit on the baseline and
            // reach only to x-height, so they are neither; a slash is too
            // thin and too sparse to be a digit.
            let raised = CGFloat(baseline - c.maxY) > capHeight * 0.22
            let hung = abs(CGFloat(c.minY) - capTop) < capHeight * 0.15 && h >= capHeight * 0.4
            let digitShaped = w >= h * 0.35 && CGFloat(c.pixels) >= w * h * 0.25 && h >= capHeight * 0.35
            if raised || hung, h < capHeight * 0.8, digitShaped {
                return Part(component: c, kind: .superscript)
            }
            // A bracket: thin, taller than a capital, and curved — its ink
            // sits to one side in the middle rows and to the other at the
            // ends, where a j with its dot glued on runs straight down.
            if h > capHeight * 1.1, w < capHeight * 0.4, isCurved(c) { return Part(component: c, kind: .paren) }
            return Part(component: c, kind: .body)
        }
    }

    /// Two thin uprights inside the glyph and two bars away from its top
    /// and bottom. A B or a D has its upright at the edge; a G, a C, an
    /// E has a wide stroke along its top or bottom; an H has one bar,
    /// in the middle.
    static func isSharp(_ c: Component, capHeight: CGFloat) -> Bool {
        let h = CGFloat(c.height), w = CGFloat(c.width)
        guard h >= capHeight * 0.75, h <= capHeight * 1.6, w >= capHeight * 0.3, w <= capHeight * 0.95 else { return false }
        let uprights = runs(strokeHeights(c).map { $0 >= h * 0.6 })
        guard uprights.count == 2 else { return false }
        for run in uprights {
            let centre = CGFloat(run.lowerBound + run.upperBound) / 2 / w
            guard CGFloat(run.count) <= max(2, w * 0.4), centre > 0.12, centre < 0.88 else { return false }
        }
        // The bars, by the ink between the uprights — slanted on an
        // italic ♯, so a row holds only part of one; a beam fused to the
        // foot is not one.
        let gap = uprights[1].lowerBound - uprights[0].upperBound
        guard gap >= 2 else { return false }
        var between = [Int](repeating: 0, count: c.height)
        for p in c.points {
            let px = p % c.stripWidth - c.minX
            if px >= uprights[0].upperBound, px < uprights[1].lowerBound { between[p / c.stripWidth - c.minY] += 1 }
        }
        let bars = runs(between.map { CGFloat($0) >= CGFloat(gap) * 0.6 })
            .filter { let m = CGFloat($0.lowerBound + $0.upperBound) / 2 / h; return m > 0.1 && m < 0.9 }
        guard (1...3).contains(bars.count) else { return false }
        if bars.count == 1, (0.4...0.6).contains(CGFloat(bars[0].lowerBound + bars[0].upperBound) / 2 / h) { return false }
        // Top and bottom rows hold only the two uprights — the bottom
        // excused when the glyph is taller than a capital, which is a
        // beam fused to its foot.
        let edge = max(1, c.height / 10)
        let topInk = c.rows.prefix(edge).max() ?? 0, bottomInk = c.rows.suffix(edge).max() ?? 0
        return CGFloat(topInk) <= w * 0.5 && (CGFloat(bottomInk) <= w * 0.5 || h > capHeight * 1.2)
    }

    /// An upright on the left with a bowl on the right, in the lower part
    /// — and nothing else up top, which is what parts it from a B.
    static func isFlat(_ c: Component, capHeight: CGFloat) -> Bool {
        let h = CGFloat(c.height), w = CGFloat(c.width)
        guard h >= capHeight * 0.9, w >= capHeight * 0.25, w <= capHeight * 0.6 else { return false }
        let stemColumns = max(2, c.width / 4)
        guard c.columns.prefix(stemColumns).contains(where: { CGFloat($0) >= h * 0.8 }),
              !c.columns.suffix(c.width / 2).contains(where: { CGFloat($0) >= h * 0.8 }) else { return false }
        // Right of the stem: empty in the top third, inked below.
        var upper = 0, lower = 0
        let third = c.height / 3
        for p in c.points {
            let x = p % stripWidthHint(c) - c.minX, y = p / stripWidthHint(c) - c.minY
            guard x >= stemColumns + 1 else { continue }
            if y < third { upper += 1 } else { lower += 1 }
        }
        let rightWidth = c.width - stemColumns - 1
        guard rightWidth > 0 else { return false }
        // The bowl closes back to the stem: the bottom rows are narrow.
        // A note's flag, a wedge, is widest there.
        let foot = c.rows.suffix(max(1, c.height / 7))
        guard foot.allSatisfy({ CGFloat($0) <= w * 0.6 }) else { return false }
        return Double(upper) < Double(rightWidth * third) * 0.12 && Double(lower) > Double(rightWidth * (c.height - third)) * 0.2
    }

    /// Blobs stacked with next to no gap and one above the other — the
    /// base of a 2 that a thin stroke parted from its hook at twice the
    /// size — put back together, so neither reads as a 7.
    static func glued(_ blobs: [Component], unit: CGFloat) -> [Component] {
        var out = blobs
        let reach = max(1, Int(unit / 8))
        var merged = true
        while merged {
            merged = false
            outer: for i in out.indices {
                for j in out.indices where j != i {
                    let a = out[i], b = out[j]
                    let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) + 1
                    guard overlap >= Int(Double(min(a.width, b.width)) * 0.6) else { continue }
                    let gap = max(b.minY - a.maxY, a.minY - b.maxY)
                    guard gap >= 0, gap <= reach,
                          CGFloat(max(a.maxY, b.maxY) - min(a.minY, b.minY)) <= unit * 2.5 else { continue }
                    out[i] = joined(a, b)
                    out.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return out
    }

    private static func joined(_ a: Component, _ b: Component) -> Component {
        var c = Component(minX: min(a.minX, b.minX), minY: min(a.minY, b.minY), maxX: max(a.maxX, b.maxX), maxY: max(a.maxY, b.maxY),
                          pixels: a.pixels + b.pixels, stripWidth: a.stripWidth,
                          columns: [Int](repeating: 0, count: max(a.maxX, b.maxX) - min(a.minX, b.minX) + 1),
                          rows: [Int](repeating: 0, count: max(a.maxY, b.maxY) - min(a.minY, b.minY) + 1))
        c.points = a.points + b.points
        for p in c.points { c.columns[p % c.stripWidth - c.minX] += 1; c.rows[p / c.stripWidth - c.minY] += 1 }
        return c
    }

    /// Whether the ink bows: the middle rows' centre is well to one side
    /// of the end rows' centre, as in a bracket and not in a stem.
    static func isCurved(_ c: Component) -> Bool {
        var sum = [Double](repeating: 0, count: c.height), count = [Double](repeating: 0, count: c.height)
        for p in c.points {
            let y = p / c.stripWidth - c.minY
            sum[y] += Double(p % c.stripWidth - c.minX); count[y] += 1
        }
        func centre(_ rows: Range<Int>) -> Double? {
            let s = rows.reduce(0.0) { $0 + sum[$1] }, n = rows.reduce(0.0) { $0 + count[$1] }
            return n > 0 ? s / n : nil
        }
        let fifth = max(1, c.height / 5), third = max(1, c.height / 3)
        guard let ends = centre(0..<fifth).flatMap({ top in centre((c.height - fifth)..<c.height).map { ($0 + top) / 2 } }),
              let middle = centre(third..<(c.height - third)) else { return false }
        return abs(middle - ends) >= Double(c.width) * 0.3
    }

    /// The strip width a component's points were indexed in.
    private static func stripWidthHint(_ c: Component) -> Int { c.stripWidth }

    /// Column by column, the longest unbroken run of ink: an upright is
    /// one stroke, where a 9's side is a bowl and a tail that only add up.
    static func strokeHeights(_ c: Component) -> [CGFloat] {
        var grid = [Bool](repeating: false, count: c.width * c.height)
        for p in c.points { grid[(p / c.stripWidth - c.minY) * c.width + (p % c.stripWidth - c.minX)] = true }
        return (0..<c.width).map { x in
            var best = 0, run = 0
            for y in 0..<c.height {
                run = grid[y * c.width + x] ? run + 1 : 0
                best = max(best, run)
            }
            return CGFloat(best)
        }
    }

    private static func runs(_ flags: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        for (i, f) in flags.enumerated() {
            if f, start == nil { start = i }
            if !f, let s = start { out.append(s..<i); start = nil }
        }
        if let s = start { out.append(s..<flags.count) }
        return out
    }

    // MARK: - Superscript digits

    /// A raised small glyph named by its shape against digits drawn in
    /// the faces charts are set in. Nil when nothing matches well.
    static func digit(_ c: Component, gray: [UInt8], stripWidth: Int, threshold: UInt8) -> String? {
        let best = bestDigit(c, gray: gray, stripWidth: stripWidth, threshold: threshold)
        return best.score >= 0.33 ? best.text : nil
    }

    static func bestDigit(_ c: Component, gray: [UInt8], stripWidth: Int, threshold: UInt8) -> (text: String, score: Double) {
        let bitmap = normalised(c, gray: gray, stripWidth: stripWidth, threshold: threshold)
        var best: (text: String, score: Double) = ("", 0)
        for (text, template) in templates {
            let score = similarity(bitmap, template)
            if score > best.score { best = (text, score) }
        }
        return best
    }

    static let cell = 16

    /// The blob's ink on a cell × cell grid, its box stretched to fill it.
    static func normalised(_ c: Component, gray: [UInt8], stripWidth: Int, threshold: UInt8) -> [Double] {
        var out = [Double](repeating: 0, count: cell * cell)
        var counts = [Int](repeating: 0, count: cell * cell)
        for y in c.minY...c.maxY {
            for x in c.minX...c.maxX {
                let gx = min(cell - 1, (x - c.minX) * cell / c.width)
                let gy = min(cell - 1, (y - c.minY) * cell / c.height)
                counts[gy * cell + gx] += 1
                if gray[y * stripWidth + x] < threshold { out[gy * cell + gx] += 1 }
            }
        }
        for i in out.indices where counts[i] > 0 { out[i] /= Double(counts[i]) }
        return out
    }

    /// Correlation of two grids, 0…1 — each softened first, so a stroke
    /// a cell over still counts.
    static func similarity(_ a: [Double], _ b: [Double]) -> Double {
        let a = softened(a), b = softened(b)
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        guard da > 0, db > 0 else { return 0 }
        return max(0, num / (da * db).squareRoot())
    }

    /// A lone letter named against A–G drawn in the faces charts use.
    static func letter(_ c: Component, gray: [UInt8], stripWidth: Int, threshold: UInt8) -> String? {
        let bitmap = normalised(c, gray: gray, stripWidth: stripWidth, threshold: threshold)
        var best: (String, Double) = ("", 0)
        for (text, template) in letterTemplates {
            let score = similarity(bitmap, template)
            if score > best.1 { best = (text, score) }
        }
        let h = CGFloat(c.height), w = CGFloat(c.width)
        guard w >= h * 0.5, w <= h * 1.1 else { return nil }
        return best.1 >= 0.72 ? best.0 : nil
    }

    static let faces = ["Helvetica", "Helvetica-Bold", "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT",
                        "ArialMT", "Arial-BoldMT", "Georgia", "Verdana"]

    private static func softened(_ g: [Double]) -> [Double] {
        var out = g
        for y in 0..<cell {
            for x in 0..<cell {
                var sum = 0.0, n = 0.0
                for dy in -1...1 { for dx in -1...1 {
                    let yy = y + dy, xx = x + dx
                    guard yy >= 0, yy < cell, xx >= 0, xx < cell else { continue }
                    let weight = (dx == 0 && dy == 0) ? 2.0 : 1.0
                    sum += g[yy * cell + xx] * weight; n += weight
                } }
                out[y * cell + x] = sum / n
            }
        }
        return out
    }

    /// Digits drawn in several faces, each on the grid.
    static let templates: [(String, [Double])] = drawn("0123456789")
    static let letterTemplates: [(String, [Double])] = drawn("ABCDEFG")

    private static func drawn(_ glyphs: String) -> [(String, [Double])] {
        var out: [(String, [Double])] = []
        for face in faces {
            guard let font = CGFont(face as CFString) else { continue }
            for glyph in glyphs {
                guard let bitmap = render(String(glyph), font: font) else { continue }
                out.append((String(glyph), bitmap))
            }
        }
        return out
    }

    /// The engine's lookalikes — a Cyrillic А for A, В for B — folded
    /// back to the Latin letters a chart prints.
    static func latin(_ ch: Character) -> Character {
        let folds: [Character: Character] = ["А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "М": "M", "О": "O",
                                             "Р": "P", "Т": "T", "Х": "X", "а": "a", "е": "e", "о": "o", "р": "p",
                                             "с": "c", "т": "m", "п": "n", "х": "x", "ѕ": "s", "і": "i", "ј": "j"]
        return folds[ch] ?? ch
    }

    /// One glyph drawn large, cut to its ink, put on the grid.
    private static func render(_ text: String, font: CGFont) -> [Double]? {
        let size = 64
        let w = size * 2, h = size * 2
        var gray = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setFont(font); ctx.setFontSize(CGFloat(size))
        // CGFont glyph lookup by name: digits are 'zero' … 'nine', letters
        // their own names.
        let names = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        var glyphs: [CGGlyph] = []
        for ch in text {
            let name = ch.wholeNumberValue.map { names[$0] } ?? String(ch)
            let glyph = font.getGlyphWithGlyphName(name: name as CFString)
            guard glyph != 0 else { return nil }
            glyphs.append(glyph)
        }
        ctx.showGlyphs(glyphs, at: [CGPoint(x: size / 2, y: size / 2)])
        // Its ink, as a component.
        let comps = components(gray, width: w, height: h, threshold: 128)
        guard let glyph = comps.max(by: { $0.pixels < $1.pixels }) else { return nil }
        return normalised(glyph, gray: gray, stripWidth: w, threshold: 128)
    }
}

// MARK: - Reading a strip

extension ChordGlyphs {

    /// Every chord symbol in the strip above one staff. `unit` is the
    /// staff-line spacing in the strip's pixels; `threshold` the page's
    /// ink threshold.
    static func read(strip: CGImage, unit: CGFloat, threshold: UInt8) -> [Reading] {
        let debug = ProcessInfo.processInfo.environment["CHORDGLYPHS_DEBUG"] != nil
        let width = strip.width, height = strip.height
        if debug { print("strip \(width)x\(height) unit \(unit) threshold \(threshold) templates \(templates.count)") }
        guard width > 0, height > 0, var gray = grayscale(strip) else { return [] }
        let u = max(unit, 3)

        // Long horizontal strokes — a volta bracket, a tie, a lyric
        // underline — join every chord under them into one blob.
        let longRun = Int(u * 3)
        for y in 0..<height {
            var x = 0
            while x < width {
                guard gray[y * width + x] < threshold else { x += 1; continue }
                var end = x
                while end < width, gray[y * width + end] < threshold { end += 1 }
                if end - x >= longRun { for i in x..<end { gray[y * width + i] = 255 } }
                x = end
            }
        }
        // A slur or a tie through the strip: a stroke no thicker than a
        // fifth of a space running longer than a letter and a half. It
        // fuses the glyphs it crosses into one blob and makes an E as
        // tall as a bracket. A ♯'s bars and an E's arms are shorter.
        let thinStroke = max(1, Int(u * 0.2)), longStroke = Int(u * 1.5)
        var thin = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            var y = 0
            while y < height {
                guard gray[y * width + x] < threshold else { y += 1; continue }
                var end = y
                while end < height, gray[end * width + x] < threshold { end += 1 }
                if end - y <= thinStroke { for i in y..<end { thin[i * width + x] = true } }
                y = end
            }
        }
        for y in 0..<height {
            var x = 0
            while x < width {
                guard thin[y * width + x] else { x += 1; continue }
                var end = x
                while end < width, thin[y * width + end] { end += 1 }
                if end - x >= longStroke { for i in x..<end { gray[y * width + i] = 255 } }
                x = end
            }
        }
        // A beam along the bottom edge: a run as long as a staff space
        // on the last rows, erased before stems are followed up.
        for y in max(0, height - 3)..<height {
            var x = 0
            while x < width {
                guard gray[y * width + x] < threshold else { x += 1; continue }
                var end = x
                while end < width, gray[y * width + end] < threshold { end += 1 }
                if CGFloat(end - x) >= u { for i in x..<end { gray[y * width + i] = 255 } }
                x = end
            }
        }
        // Note stems and beams reaching up from the staff below: thin
        // strokes crossing the bottom edge, followed up and erased.
        let stemWidth = max(2, Int(u / 3))
        var x = 0
        while x < width {
            guard gray[(height - 1) * width + x] < threshold else { x += 1; continue }
            var end = x
            while end < width, gray[(height - 1) * width + end] < threshold { end += 1 }
            if end - x <= stemWidth {
                for column in x..<end {
                    var y = height - 1
                    while y >= 0, gray[y * width + column] < threshold { gray[y * width + column] = 255; y -= 1 }
                }
            }
            x = end
        }

        let raw = components(gray, width: width, height: height, threshold: threshold).filter { c in
            c.pixels >= 3
                && CGFloat(c.height) <= u * 3.5 && CGFloat(c.width) <= u * 6
                // Touching the bottom edge: a note's head, stem or beam
                // reaching up from the staff. Chords stand clear of it.
                && !(c.maxY >= height - 1 && CGFloat(c.height) >= u * 0.5)
        }
        let blobs = glued(raw, unit: u)
        if let dir = ProcessInfo.processInfo.environment["CHORDGLYPHS_DUMP"] {
            dump(gray, width: width, height: height, to: dir)
        }

        var out: [Reading] = []
        var lastSuffix: Reading?
        var prose = 0
        if debug {
            print("  blobs \(blobs.count)  tokens " + tokens(blobs, unit: u).map { t in
                "[\(t.map(\.minX).min()!)-\(t.map(\.maxX).max()!)]" }.joined())
        }
        // A token's glyphs as they come; when nothing is read, its wide
        // blobs cut where their ink runs thin — on a scan the ♯ of 「F♯m」
        // touches both letters and comes as one blob — and read again.
        // Cut only then: an m cut at its arches reads as nothing at all.
        func readToken(_ token: [Component]) -> Reading? {
            // A blob as tall as a capital and wider than it is high is
            // glyphs touching — 「F♯m」 on a scan — never one letter.
            let tallest = token.filter { CGFloat($0.width) >= CGFloat($0.height) * 0.45 }.map(\.height).max() ?? 0
            let token = token.flatMap { c -> [Component] in
                guard CGFloat(c.height) >= CGFloat(tallest) * 0.75, CGFloat(c.width) > CGFloat(c.height) * 0.9 else { return [c] }
                // Cut where the ink runs thin; failing that, round a ♯
                // inside it — on a scan its bars touch the letters either
                // side with more ink than a thin column allows.
                let thin = split(c, width: width)
                if thin.count > 1 { return thin }
                if let round = cutSharp(c, width: width) { return round }
                if debug { print("  uncut \(c.width)x\(c.height)@\(c.minX)\n" + art(c)) }
                return [c]
            }
            let parts = parts(token)
            let body = parts.filter { $0.kind == .body }
            let describe = { parts.map { "\($0.kind)\($0.component.width)x\($0.component.height)@\($0.component.minX)" }.joined(separator: " ") }
            guard !body.isEmpty else {
                // A ♯ or ♭ set apart from its letter — 「B ♭」 in a serif
                // face — is kept for the chord before it.
                if let accidental = parts.first(where: { $0.kind == .sharp || $0.kind == .flat }) {
                    let c = accidental.component
                    lastSuffix = Reading(text: accidental.kind == .sharp ? "#" : "b",
                                         box: CGRect(x: c.minX, y: c.minY, width: c.width, height: c.height), confidence: 0.5)
                }
                if debug { print("  skip, no body: [\(describe())]") }
                return nil
            }
            // The token's box, brackets and noise aside.
            let kept = parts.filter { $0.kind != .paren && $0.kind != .noise }.map(\.component)
            let minX = kept.map(\.minX).min()!, maxX = kept.map(\.maxX).max()!
            let minY = kept.map(\.minY).min()!, maxY = kept.map(\.maxY).max()!
            let cap = CGFloat(body.map(\.component.height).max()!)
            if debug {
                let others = body.map(\.component.height).sorted()
                for part in body where body.count > 1 && CGFloat(part.component.height) > CGFloat(others[others.count - 2]) * 1.15
                    && CGFloat(part.component.width) <= CGFloat(part.component.height) * 0.7 {
                    print("  NARROW TALL \(part.component.width)x\(part.component.height)@\(part.component.minX)\n" + art(part.component).replacingOccurrences(of: "      ", with: "    | "))
                }
            }
            guard cap >= u * 0.45, cap <= u * 3 else { if debug { print("  skip, cap \(cap): [\(describe())]") }; return nil }

            // The letters alone, for the text engine: set together — the
            // room a ♯ or a raised digit took closed up, since a gap in
            // a word costs the engine the rest of it — large, on white.
            let ordered = parts.sorted { $0.component.minX < $1.component.minX }
            var shift = 0
            var placed: [(part: Part, shift: Int)] = []
            var previousEnd: Int?
            for part in ordered {
                if part.kind == .body {
                    placed.append((part, shift))
                } else if let end = previousEnd, part.component.minX > end {
                    // Closed up to a letter's gap, not to nothing.
                    shift += part.component.maxX - part.component.minX + 1 - max(1, Int(cap * 0.08))
                }
                previousEnd = max(previousEnd ?? 0, part.component.maxX)
            }
            let margin = Int(cap)
            let x0 = max(0, minX - margin), y0 = max(0, minY - margin)
            let x1 = min(width - 1, maxX + margin), y1 = min(height - 1, maxY + margin)
            let cw = x1 - x0 + 1, ch = y1 - y0 + 1
            var letters = [UInt8](repeating: 255, count: cw * ch)
            for (part, offset) in placed {
                for p in part.component.points {
                    let px = p % width - x0 - offset, py = p / width - y0
                    if px >= 0, px < cw, py >= 0, py < ch { letters[py * cw + px] = gray[p] }
                }
            }
            let scale = max(2, min(8, Int((48 / cap).rounded())))
            guard let cut = image(letters, width: cw, height: ch), let big = enlarged(cut, by: scale) else { return nil }
            var pieces: [(x: CGFloat, text: String)] = []
            var confidence: Float = 0
            if let (string, line, conf) = recogniseLetters(big) {
                confidence = conf
                let chars = string.folding(options: .diacriticInsensitive, locale: nil).filter { !$0.isWhitespace }.map(latin)
                // Each character where its glyph is: one to one when the
                // engine read as many as there are glyphs — else spread
                // across what it read, in order.
                if debug { print("  read 「\(string)」 for " + placed.map { "\($0.part.component.width)x\($0.part.component.height)@\($0.part.component.minX)" }.joined(separator: " ")) }
                if chars.count == placed.count {
                    for (char, slot) in zip(chars, placed) {
                        var text = String(char)
                        // A small digit — the 2 of 「A2」 at the baseline —
                        // which the engine takes for a 7: named by its
                        // shape when that is sure.
                        let c = slot.part.component
                        if char.isNumber, slot.part !== placed[0].part || placed.count == 1, CGFloat(c.height) < cap * 0.8 || placed.count == 1 {
                            let best = bestDigit(c, gray: gray, stripWidth: width, threshold: threshold)
                            if debug { print("  small digit read \(char), shaped like \(best.text) \(String(format: "%.2f", best.score))") }
                            if best.score >= 0.5 { text = best.text }
                        }
                        pieces.append((CGFloat(c.minX), text))
                    }
                } else {
                    let left = CGFloat(x0) + line.minX * CGFloat(big.width) / CGFloat(scale)
                    let span = line.width * CGFloat(big.width) / CGFloat(scale)
                    for (i, char) in chars.enumerated() {
                        let drawn = left + span * (CGFloat(i) + 0.5) / CGFloat(chars.count)
                        // The letter it falls on, as drawn — or the nearest.
                        func distance(_ p: (part: Part, shift: Int)) -> CGFloat {
                            let lo = CGFloat(p.part.component.minX - p.shift), hi = CGFloat(p.part.component.maxX - p.shift)
                            return drawn < lo ? lo - drawn : drawn > hi ? drawn - hi : 0
                        }
                        let under = placed.indices.min { distance(placed[$0]) < distance(placed[$1]) }
                        pieces.append((drawn + CGFloat(under.map { placed[$0].shift } ?? 0), String(char)))
                    }
                }
            }
            // A lone glyph, which the engine often will not name: against
            // the letters drawn in the faces charts use.
            if pieces.isEmpty, body.count == 1,
               let named = letter(body[0].component, gray: gray, stripWidth: width, threshold: threshold) {
                pieces = [(CGFloat(body[0].component.minX), named)]
                confidence = max(confidence, 0.5)
            }
            // A glyph at either end that no piece stands for — the capital
            // the engine left off the front of 「maj7」, the 2 of 「A2」 it
            // skipped — named by its shape: a capital against the letters,
            // a small one against the digits, when that is sure. Not in
            // the middle, where a piece set a little off would be doubled.
            for (i, slot) in placed.enumerated() where i == 0 || i == placed.count - 1 {
                let c = slot.part.component
                guard !pieces.contains(where: { Int($0.x) >= c.minX - 2 && Int($0.x) <= c.maxX + 2 }) else { continue }
                if debug {
                    let d = bestDigit(c, gray: gray, stripWidth: width, threshold: threshold)
                    print("  unread glyph \(c.width)x\(c.height)@\(c.minX): digit \(d.text) \(String(format: "%.2f", d.score)), letter \(letter(c, gray: gray, stripWidth: width, threshold: threshold) ?? "-")")
                }
                if CGFloat(c.height) >= cap * 0.9, let named = letter(c, gray: gray, stripWidth: width, threshold: threshold) {
                    if i == 0 { pieces.removeAll { Int($0.x) < c.minX } }
                    pieces.append((CGFloat(c.minX), named))
                } else if i > 0, CGFloat(c.height) < cap * 0.8, CGFloat(c.width) >= CGFloat(c.height) * 0.35 {
                    let best = bestDigit(c, gray: gray, stripWidth: width, threshold: threshold)
                    if best.score >= 0.5 { pieces.append((CGFloat(c.minX), best.text)) }
                }
            }
            // Nothing read letter by letter: the token as printed, whole,
            // which the engine sometimes reads where it read no part.
            if pieces.isEmpty, let whole = strip.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)),
               let bigWhole = enlarged(whole, by: scale), let (plain, _, conf) = recogniseLetters(bigWhole) {
                var bare = plain.folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: " ", with: "")
                if bare.hasPrefix("("), bare.hasSuffix(")"), bare.count > 2 { bare = String(bare.dropFirst().dropLast()) }
                let text = ScoreRecognition.repairedChordWord(String(bare.map(latin)))
                if let parsed = ScoreChordText.parse(text) {
                    if debug { print("  whole token read 「\(plain)」 → \(text)") }
                    return Reading(text: ScoreChordText.transpose(parsed, by: 0),
                                   box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), confidence: conf)
                }
            }
            guard !pieces.isEmpty else { if debug { print("  skip, unread: [\(describe())]") }; return nil }
            for part in parts {
                let x = CGFloat(part.component.minX)
                switch part.kind {
                case .sharp:
                    pieces.append((x, "#"))
                    if debug { print("  SHARP \(part.component.width)x\(part.component.height)@\(part.component.minX)\n" + art(part.component).replacingOccurrences(of: "      ", with: "    # ")) }
                case .flat:
                    pieces.append((x, "b"))
                    if debug { print("  FLAT \(part.component.width)x\(part.component.height)@\(part.component.minX)\n" + art(part.component).replacingOccurrences(of: "      ", with: "    b ")) }
                case .superscript:
                    if let d = digit(part.component, gray: gray, stripWidth: width, threshold: threshold) {
                        pieces.append((x, d))
                    } else if debug {
                        let best = bestDigit(part.component, gray: gray, stripWidth: width, threshold: threshold)
                        print("  superscript unnamed: \(part.component.width)x\(part.component.height)@\(part.component.minX) best \(best.text) \(String(format: "%.2f", best.score))")
                    }
                case .body, .paren, .noise: break
                }
            }
            if debug { print("  pieces " + pieces.sorted { $0.x < $1.x }.map { "\($0.text)@\(Int($0.x))" }.joined(separator: " ")) }
            var composed = pieces.sorted { $0.x < $1.x }.map(\.text).joined()
            // 「(E7)」: an optional chord; the brackets are not its name.
            if composed.hasPrefix("("), composed.hasSuffix(")"), composed.count > 2 {
                composed = String(composed.dropFirst().dropLast())
            }
            var text = ScoreRecognition.repairedChordWord(composed)
            // 「EbmaJ7」: the engine's capitals in the quality, where a
            // chart has none but the M of a major seventh.
            if ScoreChordText.parse(text) == nil {
                var folded = ""
                for (i, ch) in text.enumerated() {
                    folded.append(i > 0 && "JSUADI".contains(ch) && !(i > 1 && text[text.index(text.startIndex, offsetBy: i - 1)] == "/") ? Character(ch.lowercased()) : ch)
                }
                if ScoreChordText.parse(folded) != nil { text = folded }
            }
            // 「1.Am」: the volta's number is not the chord's, nor is its
            // place — the box begins where the chord does.
            var boxMinX = minX
            if composed.hasSuffix(text), composed.count > text.count {
                let sorted = pieces.sorted { $0.x < $1.x }
                let first = min(sorted.count - 1, composed.count - text.count)
                boxMinX = max(minX, Int(sorted[first].x))
            }
            lastSuffix = nil
            if debug {
                print("  token x\(minX)-\(maxX) cap \(Int(cap)) [\(describe())] → 「\(composed)」 → 「\(text)」 parses \(ScoreChordText.parse(text) != nil)")
            }
            if ScoreChordText.parse(text) == nil, text.filter(\.isLetter).count >= 3 { prose += 1 }
            if ScoreChordText.parse(text) == nil, !text.isEmpty, ScoreChordText.parse("C" + text) != nil {
                // A quality on its own: kept for the chord before it.
                lastSuffix = Reading(text: text, box: CGRect(x: boxMinX, y: minY, width: maxX - boxMinX + 1, height: maxY - minY + 1), confidence: confidence)
            }
            if ScoreChordText.parse(text) == nil, apartable(text) {
                return Reading(text: text, box: CGRect(x: boxMinX, y: minY, width: maxX - boxMinX + 1, height: maxY - minY + 1), confidence: confidence)
            }
            if ScoreChordText.parse(text) == nil {
                // The whole token as printed, read plain — for a chart whose
                // ♯ is a text character the engine already knows.
                guard let whole = strip.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)),
                      let bigWhole = enlarged(whole, by: scale),
                      let (plain, _, conf) = recogniseLetters(bigWhole) else { return nil }
                var bare = plain.replacingOccurrences(of: " ", with: "")
                if bare.hasPrefix("("), bare.hasSuffix(")"), bare.count > 2 { bare = String(bare.dropFirst().dropLast()) }
                text = ScoreRecognition.repairedChordWord(String(bare.map(latin)))
                guard ScoreChordText.parse(text) != nil else { return nil }
                confidence = conf
            }
            // Spelled as the grammar has it: 「EbmaJ7」 is Ebmaj7.
            if let parsed = ScoreChordText.parse(text) { text = ScoreChordText.transpose(parsed, by: 0) }
            return Reading(text: text,
                           box: CGRect(x: boxMinX, y: minY, width: maxX - boxMinX + 1, height: maxY - minY + 1),
                           confidence: confidence)
        }
        for token in tokens(blobs, unit: u) {
            if let reading = readToken(token) { out.append(contentsOf: apart(reading)); continue }
            let kept = lastSuffix
            let cut = token.flatMap { split($0, width: width) }
            if cut.count > token.count, let reading = readToken(cut) { out.append(contentsOf: apart(reading)); continue }
            if lastSuffix == nil { lastSuffix = kept }
            // A quality set apart from its root — 「A 2」, 「B m7」 — joins the
            // chord just before it.
            if let last = out.last, let suffix = lastSuffix,
               CGFloat(suffix.box.minX - last.box.maxX) < last.box.height * 1.5,
               abs(suffix.box.midY - last.box.midY) < last.box.height,
               // Not a note's stem and head from the staff below, which
               // is shaped like a ♭: an accidental stands on the chord's
               // baseline at the chord's height.
               suffix.text.count > 1 || (abs(suffix.box.maxY - last.box.maxY) < last.box.height * 0.35
                                         && (0.7...1.6).contains(suffix.box.height / last.box.height)),
               ScoreChordText.parse(last.text + suffix.text) != nil {
                out[out.count - 1] = Reading(text: last.text + suffix.text, box: last.box.union(suffix.box),
                                             confidence: last.confidence)
                if debug { print("  joined 「\(suffix.text)」 to 「\(last.text)」") }
            }
        }
        // A strip of words — a title, a verse that strayed into the band —
        // is no place for a lone letter named by its shape.
        if prose >= 3 { out.removeAll { $0.text.count == 1 && $0.confidence <= 0.5 } }
        return out
    }

    private static func apartable(_ text: String) -> Bool {
        let chars = Array(text)
        return (2..<max(2, chars.count - 1)).contains { i in
            "ABCDEFG".contains(chars[i])
                && ScoreChordText.parse(ScoreRecognition.repairedChordWord(String(chars[..<i]))) != nil
                && ScoreChordText.parse(ScoreRecognition.repairedChordWord(String(chars[i...]))) != nil
        }
    }

    /// 「D/EEm」: two chords whose glyphs ran together, told apart at the
    /// capital where the second begins — if both halves are chords.
    private static func apart(_ reading: Reading) -> [Reading] {
        guard ScoreChordText.parse(reading.text) == nil else { return [reading] }
        let text = Array(reading.text)
        // Each cut at a capital, scored: a half that is a chord as read
        // counts double one that needs repairing — 「DIE|Em」 over 「DI|EEm」.
        func worth(_ half: String) -> Int {
            ScoreChordText.parse(half) != nil ? 2 : ScoreChordText.parse(ScoreRecognition.repairedChordWord(half)) != nil ? 1 : 0
        }
        var best: (at: Int, score: Int)?
        for i in 2..<max(2, text.count - 1) where "ABCDEFG".contains(text[i]) {
            let left = worth(String(text[..<i])), right = worth(String(text[i...]))
            guard left > 0, right > 0 else { continue }
            if best == nil || left + right > best!.score { best = (i, left + right) }
        }
        guard let best else { return [] }
        let i = best.at
        let left = ScoreRecognition.repairedChordWord(String(text[..<i]))
        let right = ScoreRecognition.repairedChordWord(String(text[i...]))
        let share = CGFloat(i) / CGFloat(text.count)
        let cut = reading.box.minX + reading.box.width * share
        return [Reading(text: left, box: CGRect(x: reading.box.minX, y: reading.box.minY, width: cut - reading.box.minX, height: reading.box.height), confidence: reading.confidence),
                Reading(text: right, box: CGRect(x: cut, y: reading.box.minY, width: reading.box.maxX - cut, height: reading.box.height), confidence: reading.confidence)]
    }

    /// The text engine on an image of letters: the string, the line's box
    /// (normalised, origin top-left), the confidence.
    private static func recogniseLetters(_ image: CGImage) -> (String, CGRect, Float)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let best = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let candidate = best.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
        let b = best.boundingBox
        return (candidate.string, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), candidate.confidence)
    }

    /// A blob wider than it is tall cut where its ink runs thin: on a
    /// scan the ♯ of 「F♯m」 touches both letters and comes as one blob.
    /// Cut only where a column holds next to nothing, into pieces each
    /// at least a stroke wide.
    static func split(_ c: Component, width stripWidth: Int) -> [Component] {
        let h = c.height, w = c.width
        guard w > Int(Double(h) * 0.9), w >= 6 else { return [c] }
        let thin = max(1, h / 12)
        var cuts: [Int] = []
        var x = 1
        while x < w - 1 {
            guard c.columns[x] <= thin else { x += 1; continue }
            var end = x
            while end + 1 < w - 1, c.columns[end + 1] <= thin { end += 1 }
            let cut = (x + end) / 2
            let minPiece = max(2, h / 5)
            if cut >= (cuts.last.map { $0 + minPiece } ?? minPiece), w - 1 - cut >= minPiece { cuts.append(cut) }
            x = end + 1
        }
        guard !cuts.isEmpty else { return [c] }
        var pieces: [Component] = []
        var start = 0
        for bound in cuts + [w] {
            if bound - 1 >= start, let part = piece(of: c, columns: start...(bound - 1), width: stripWidth) { pieces.append(part) }
            start = bound + 1
        }
        return pieces.isEmpty ? [c] : pieces
    }

    /// A ♯ inside a wider blob, found by its two thin uprights with two
    /// bars between them, and the blob cut round it: what is left of it,
    /// the ♯, what is right of it.
    static func cutSharp(_ c: Component, width stripWidth: Int) -> [Component]? {
        let h = CGFloat(c.height)
        let strokes = strokeHeights(c)
        let tallest = strokes.max() ?? 0
        let uprights = runs(strokes.map { $0 >= max(h * 0.4, tallest * 0.72) })
        guard uprights.count >= 2 else { return nil }
        let thin = max(2, Int(h * 0.16))
        for i in 0..<(uprights.count - 1) {
            let a = uprights[i], b = uprights[i + 1]
            guard a.count <= thin, b.count <= thin else { continue }
            let gap = b.lowerBound - a.upperBound
            guard gap >= 2, CGFloat(gap) <= h * 0.5 else { continue }
            // Between the uprights: the two bars, and little else.
            var between = [Int](repeating: 0, count: c.height)
            for p in c.points {
                let px = p % stripWidth - c.minX
                if px >= a.upperBound, px < b.lowerBound { between[p / stripWidth - c.minY] += 1 }
            }
            // The bars within the glyph; a beam fused to its foot is not one.
            let bars = runs(between.map { CGFloat($0) >= CGFloat(gap) * 0.6 })
                .filter { let m = CGFloat($0.lowerBound + $0.upperBound) / 2 / h; return m > 0.1 && m < 0.9 }
            guard (1...3).contains(bars.count),
                  !(bars.count == 1 && (0.4...0.6).contains(CGFloat(bars[0].lowerBound + bars[0].upperBound) / 2 / h))
            else { continue }
            let overhang = max(1, Int(h * 0.08))
            let left = max(0, a.lowerBound - overhang), right = min(c.width - 1, b.upperBound + overhang)
            let pieces = [(0, left - 1), (left, right), (right + 1, c.width - 1)].compactMap { (x0, x1) -> Component? in
                guard x1 >= x0, x1 - x0 + 1 >= 2 else { return nil }
                return piece(of: c, columns: x0...x1, width: stripWidth)
            }
            return pieces.count >= 2 ? pieces : nil
        }
        return nil
    }

    /// The part of a blob within a range of its columns.
    static func piece(of c: Component, columns range: ClosedRange<Int>, width stripWidth: Int) -> Component? {
        let x0 = c.minX + range.lowerBound, x1 = c.minX + range.upperBound
        var piece = Component(minX: stripWidth, minY: c.maxY, maxX: 0, maxY: 0, pixels: 0, stripWidth: stripWidth,
                              columns: [Int](repeating: 0, count: x1 - x0 + 1),
                              rows: [Int](repeating: 0, count: c.height))
        for p in c.points {
            let px = p % stripWidth, py = p / stripWidth
            guard px >= x0, px <= x1 else { continue }
            piece.points.append(p); piece.pixels += 1
            piece.minX = min(piece.minX, px); piece.maxX = max(piece.maxX, px)
            piece.minY = min(piece.minY, py); piece.maxY = max(piece.maxY, py)
            piece.columns[px - x0] += 1; piece.rows[py - c.minY] += 1
        }
        guard piece.pixels > 0 else { return nil }
        piece.columns = Array(piece.columns[(piece.minX - x0)...(piece.maxX - x0)])
        piece.rows = Array(piece.rows[(piece.minY - c.minY)...(piece.maxY - c.minY)])
        return piece
    }

    /// The blob's ink as text, for the dump.
    static func art(_ c: Component) -> String {
        var grid = [[Character]](repeating: [Character](repeating: ".", count: c.width), count: c.height)
        for p in c.points { grid[p / c.stripWidth - c.minY][p % c.stripWidth - c.minX] = "#" }
        return grid.map { "      " + String($0) }.joined(separator: "\n")
    }

    private static var dumped = 0
    private static func dump(_ gray: [UInt8], width: Int, height: Int, to dir: String) {
        guard let img = image(gray, width: width, height: height) else { return }
        dumped += 1
        let url = URL(fileURLWithPath: dir).appendingPathComponent("strip-\(dumped).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
    }

    static func grayscale(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return gray
    }

    private static func image(_ gray: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = gray
        guard let context = CGContext(data: &copy, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        return context.makeImage()
    }

    private static func enlarged(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor, height = image.height * factor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
