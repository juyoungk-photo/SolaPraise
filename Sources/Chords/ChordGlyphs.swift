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
import Vision

enum ChordGlyphs {

    /// One blob of ink, in the strip's pixel coordinates.
    struct Component {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var pixels: Int
        /// Column by column, how many pixels of the blob are inked.
        var columns: [Int]
        /// Row by row.
        var rows: [Int]

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var midX: CGFloat { CGFloat(minX + maxX) / 2 }
    }

    enum Kind: Equatable { case sharp, flat, superscript, paren, body }

    struct Part {
        let component: Component
        let kind: Kind
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
            var c = Component(minX: width, minY: height, maxX: 0, maxY: 0, pixels: 0,
                              columns: [Int](repeating: 0, count: width), rows: [Int](repeating: 0, count: height))
            stack = [start]
            label[start] = id
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
                c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                c.pixels += 1
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
            if var last = groups.last, let tail = last.max(by: { $0.maxX < $1.maxX }) {
                let gap = CGFloat(c.minX - tail.maxX)
                let top = last.map(\.minY).min()!, bottom = last.map(\.maxY).max()!
                let overlaps = c.maxY >= top - Int(unit) && c.minY <= bottom + Int(unit)
                if gap < unit * 0.55 && overlaps {
                    last.append(c); groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([c])
        }
        return groups
    }

    /// What each blob of a token is, by its shape. `cap` is the token's
    /// capital height in pixels: the tallest blob that is not a ♭ or a
    /// bracket, which rise above the letters.
    static func parts(_ token: [Component]) -> [Part] {
        guard !token.isEmpty else { return [] }
        let bottom = token.map(\.maxY).max()!
        // Capital height: the tallest among the blobs standing on the
        // baseline, discounting any that is a thin upright (a ♭'s stem, a
        // bracket) taller than the rest.
        let standing = token.filter { bottom - $0.maxY <= max(2, $0.height / 5) }
        let heights = standing.map { CGFloat($0.height) }.sorted()
        let cap = heights.isEmpty ? CGFloat(token.map(\.height).max()!) : heights[heights.count / 2 > 0 ? heights.count - 1 : 0]
        let capHeight = max(cap, 4)

        return token.map { c in
            let h = CGFloat(c.height), w = CGFloat(c.width)
            let raised = CGFloat(bottom - c.maxY) > capHeight * 0.22
            // A small glyph with its foot above the baseline: a superscript.
            if raised, h < capHeight * 0.8, c.pixels > 3 {
                return Part(component: c, kind: .superscript)
            }
            if isSharp(c, capHeight: capHeight) { return Part(component: c, kind: .sharp) }
            if isFlat(c, capHeight: capHeight) { return Part(component: c, kind: .flat) }
            // A bracket: very thin and taller than a capital.
            if h > capHeight * 1.1, w < capHeight * 0.3 { return Part(component: c, kind: .paren) }
            return Part(component: c, kind: .body)
        }
    }

    /// Two uprights and two bars, as tall as a capital or taller.
    static func isSharp(_ c: Component, capHeight: CGFloat) -> Bool {
        let h = CGFloat(c.height), w = CGFloat(c.width)
        guard h >= capHeight * 0.75, w >= capHeight * 0.3, w <= capHeight * 0.95 else { return false }
        // Uprights: columns inked over most of the height, in two runs.
        let tall = c.columns.map { CGFloat($0) >= h * 0.6 }
        let uprights = runs(tall)
        guard uprights.count == 2 else { return false }
        // Bars: rows inked across most of the width, in two runs — or one
        // when the print blurs them together; never none.
        let wide = c.rows.map { CGFloat($0) >= w * 0.6 }
        let bars = runs(wide)
        guard (1...3).contains(bars.count) else { return false }
        // Not an H: an H's bar is in the middle and its uprights reach
        // the full height on both sides; a ♯'s bars sit at a third and
        // two thirds. Both uprights at full height with one centred bar
        // is the letter.
        if bars.count == 1, let bar = bars.first {
            let centre = CGFloat(bar.lowerBound + bar.upperBound) / 2 / h
            if (0.4...0.6).contains(centre) { return false }
        }
        return true
    }

    /// An upright on the left with a bowl on the right, in the lower part.
    static func isFlat(_ c: Component, capHeight: CGFloat) -> Bool {
        let h = CGFloat(c.height), w = CGFloat(c.width)
        guard h >= capHeight * 0.9, w >= capHeight * 0.25, w <= capHeight * 0.7 else { return false }
        let stemColumns = max(1, c.width / 4)
        // The stem: the leftmost columns inked nearly the full height.
        let stem = c.columns.prefix(stemColumns).allSatisfy { CGFloat($0) >= h * 0.8 }
        guard stem else { return false }
        // The bowl: ink in the right half only in the lower two thirds.
        var upperRight = 0, lowerRight = 0
        for (i, n) in c.rows.enumerated() {
            if i < c.height / 3 { upperRight += n } else { lowerRight += n }
        }
        // Rows above the bowl hold only the stem.
        let stemInk = Double(stemColumns) * Double(c.height) / 3
        return Double(upperRight) < stemInk * 1.8 && lowerRight > upperRight
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
        let bitmap = normalised(c, gray: gray, stripWidth: stripWidth, threshold: threshold)
        var best: (String, Double) = ("", 0)
        for (text, template) in templates {
            let score = similarity(bitmap, template)
            if score > best.1 { best = (text, score) }
        }
        return best.1 >= 0.62 ? best.0 : nil
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

    /// Correlation of two grids, 0…1.
    static func similarity(_ a: [Double], _ b: [Double]) -> Double {
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

    /// Digits drawn in several faces, each on the grid.
    static let templates: [(String, [Double])] = {
        var out: [(String, [Double])] = []
        let faces = ["Helvetica", "Helvetica-Bold", "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT",
                     "ArialMT", "Arial-BoldMT", "Georgia", "Verdana"]
        for face in faces {
            guard let font = CGFont(face as CFString) else { continue }
            for digit in "0123456789" {
                guard let bitmap = render(String(digit), font: font) else { continue }
                out.append((String(digit), bitmap))
            }
        }
        return out
    }()

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
        // CGFont glyph lookup by name: digits are 'zero' … 'nine'.
        let names = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        var glyphs: [CGGlyph] = []
        for ch in text {
            guard let v = ch.wholeNumberValue else { return nil }
            glyphs.append(font.getGlyphWithGlyphName(name: names[v] as CFString))
        }
        ctx.showGlyphs(glyphs, at: [CGPoint(x: size / 2, y: size / 2)])
        // Its ink, as a component.
        let comps = components(gray, width: w, height: h, threshold: 128)
        guard let glyph = comps.max(by: { $0.pixels < $1.pixels }) else { return nil }
        return normalised(glyph, gray: gray, stripWidth: w, threshold: 128)
    }
}
