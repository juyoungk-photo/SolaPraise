//
//  ScoreRecognition.swift
//  SolaPraise
//
//  Finding the chord symbols on one page image, and where each one sits.
//
//  Kept to Vision and CoreGraphics — no UIKit — so the same code that runs
//  in the app can be run against a rendered test page on the Mac. See
//  Tools/check-score-ocr.swift. A recogniser that quietly misses chords
//  looks exactly like a score that has none, so it needs a check that can
//  fail.
//

import Foundation
import Vision
import CoreGraphics

enum ScoreRecognition {

    /// Raised whenever recognition changes what it finds. A chart read by
    /// an older version and never corrected by hand is read again, so an
    /// improvement reaches charts already opened — not only new ones.
    static let version = 7

    /// One chord found on a page.
    struct Found: Identifiable, Equatable {
        let id = UUID()
        let original: String
        /// Normalised image coordinates, origin top-left.
        let box: CGRect
        let confidence: Float

        static func == (l: Found, r: Found) -> Bool { l.id == r.id }
    }

    /// Every chord symbol on the page.
    ///
    /// Several passes, merged. Vision is unreliable on a lone capital —
    /// a "C" by itself on a line is often not reported as text at all, and
    /// which lone letters it drops changes with the language order and the
    /// size of the image around them. Measured on a rendered page: one
    /// full-page pass missed every isolated C; the Korean-first order found
    /// some; a strip cropped to a single chord line found the rest. So:
    ///
    /// 1. the whole page, English first, then Korean first;
    /// 2. a strip across every chord line found so far, and across the
    ///    space just above every lyric line — where chords sit on a lead
    ///    sheet even when the first passes found none on that line.
    ///
    /// Results are merged by position, so a chord found twice is kept once.
    static func chords(in image: CGImage) -> [Found] {
        var found: [Found] = []
        var lyricLines: [CGRect] = []
        var koreanWords: [CGRect] = []

        for languages in [["en-US", "ko-KR"], ["ko-KR", "en-US"]] {
            let pass = recognise(image, languages: languages)
            merge(pass.chords, into: &found)
            lyricLines += pass.lyricLines
            koreanWords += pass.koreanWords
        }

        for band in bands(chords: found, lyricLines: lyricLines) {
            let pixels = CGRect(x: 0,
                                y: band.minY * CGFloat(image.height),
                                width: CGFloat(image.width),
                                height: band.height * CGFloat(image.height)).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            let pass = recognise(crop, languages: ["ko-KR", "en-US"])
            // Back from the strip's coordinates to the page's.
            let mapped = pass.chords.map { item in
                Found(original: item.original,
                      box: CGRect(x: item.box.minX,
                                  y: band.minY + item.box.minY * band.height,
                                  width: item.box.width,
                                  height: item.box.height * band.height),
                      confidence: item.confidence)
            }
            merge(mapped, into: &found)
        }
        // STAFF NOTATION: chords sit above each five-line staff, with the
        // notes between them and the lyrics — not just above the lyrics,
        // which is all the strips above have looked at. On a real lead
        // sheet (거룩하신 전능의 주) the passes above found 16 of 46
        // chords: Vision does not see a row of chords between staves as a
        // line of text. So each staff is found by its lines, and the strip
        // above it is read on its own, enlarged.
        let staves = staves(in: image)
        for band in staves.map(\.band) {
            // First the strip whole, enlarged — which finds most chords and,
            // as importantly, WHERE the chord text sits in the strip.
            let pixels = CGRect(x: 0, y: band.minY * CGFloat(image.height),
                                width: CGFloat(image.width),
                                height: band.height * CGFloat(image.height)).integral
            if let crop = image.cropping(to: pixels), let strip = enlarged(crop, by: 2) {
                let mapped = recognise(strip, languages: ["en-US", "ko-KR"]).chords.map { item in
                    Found(original: item.original,
                          box: CGRect(x: item.box.minX,
                                      y: band.minY + item.box.minY * band.height,
                                      width: item.box.width,
                                      height: item.box.height * band.height),
                          confidence: item.confidence)
                }
                merge(mapped, into: &found)
            }

            // Then each word on its own, cut to the height of the chord
            // text. Note stems and beams reach up into the strip; cut at
            // the strip's full height they stuck to the letters, and a lone
            // 「C」 read as 「lu-」. Alone, on a white margin, a chord reads
            // as itself, and replaces whatever was read in its place.
            let inBand = found.filter { band.contains(CGPoint(x: 0.5, y: $0.box.midY)) }
            var textBand = band
            if !inBand.isEmpty {
                let tops = inBand.map(\.box.minY).sorted(), bottoms = inBand.map(\.box.maxY).sorted()
                let top = tops[tops.count / 2], bottom = bottoms[bottoms.count / 2]
                let margin = (bottom - top) * 0.3
                textBand = CGRect(x: 0, y: top - margin, width: 1, height: bottom - top + margin * 2)
                    .intersection(band.insetBy(dx: 0, dy: -band.height * 0.2))
            }
            // A cut that spans two chords already read is two words run
            // together — 「3.G D/E」 came back as 「D/E」 alone and took the
            // G with it. Such a cut is dropped; it replaces nothing.
            let alone = readWordsAlone(in: image, band: textBand).filter { cut in
                found.filter { item in
                    cut.box.minX < item.box.midX && item.box.midX < cut.box.maxX
                        && abs(cut.box.midY - item.box.midY) < band.height
                }.count <= 1
            }
            found.removeAll { item in
                alone.contains { $0.box.minX < item.box.maxX && item.box.minX < $0.box.maxX
                                  && abs($0.box.midY - item.box.midY) < band.height }
            }
            merge(alone, into: &found)
        }

        // A rehearsal mark is a letter in a box — 「A」 — and a letter is a
        // chord. Anything boxed is dropped.
        found.removeAll { isBoxed($0.box, in: image) }
        // Last: ink on a chord line that no pass read. Each unread blob is
        // cut out on its own, with white around it, enlarged and read
        // alone. A lone capital at the start of a line — 「C」 — went
        // unread by every whole-line pass, in either language order and
        // at twice the size; by itself it reads at once.
        merge(unreadBlobs(in: image, around: found), into: &found)

        // On a staff page nothing left of the clef is a chord: the margin
        // holds segno marks and system brackets, and the unread-ink pass
        // read one as 「A」. Checked last, after every pass has added.
        if !staves.isEmpty {
            found.removeAll { $0.box.minX < 0.07 }
            // Nothing whose ink is all Korean lyrics. Printed in a serif
            // face, 「사랑」 was read as 「A6」 and 「살아」 as 「A」 by a pass
            // that saw only Latin there, while another pass read the same
            // words as the Hangul they are. Judged by the candidate's INK,
            // line by line, against the height of one line of lyrics at
            // the top of each Korean word: Vision often reads a lyric line
            // and the chord row under it as one line, two lines tall; and a
            // chord's box is often tall enough to take in the lyric above
            // it. A box with any line of ink outside the lyrics is kept.
            let lineHeight = median(koreanWords.map(\.height)) ?? 0
            if lineHeight > 0 {
                let glyphs = koreanWords.map { word in
                    CGRect(x: word.minX, y: word.minY, width: word.width, height: min(word.height, lineHeight * 1.15))
                }
                // Ink that runs into a staff — its lines, a beam on stems
                // rising from it — is notation, not text either way. Looked
                // for a box's height below it, so a beam the box only
                // grazes is followed down to its staff.
                let staffRows = staves.map { $0.staff.insetBy(dx: 0, dy: -$0.staff.height / 8) }
                found.removeAll { item in
                    // What a syllable is misread as is short and plain —
                    // 「A」, 「A6」 — never a slash chord or a 「sus4」.
                    guard item.original.count <= 3, !item.original.contains("/") else { return false }
                    let probe = CGRect(x: item.box.minX, y: item.box.minY,
                                       width: item.box.width, height: item.box.height * 2)
                    let lines = inkLines(probe, in: image).filter { run in
                        run.minY < item.box.maxY
                            && !staffRows.contains { $0.minY < run.maxY && run.minY < $0.maxY }
                    }.map(\.midY)
                    return !lines.isEmpty && lines.allSatisfy { ink in
                        glyphs.contains { glyph in
                            let overlap = min(glyph.maxX, item.box.maxX) - max(glyph.minX, item.box.minX)
                            return overlap > item.box.width * 0.5 && glyph.minY < ink && ink < glyph.maxY
                        }
                    }
                }
                // And a chord's box no taller than its own letters. A strip
                // read whole gives boxes tall enough to take in the lyric
                // line above; the white patch a transposed chord is drawn on
                // then hid the words above it. Cut to the chord's ink: what is
                // left once lyrics and staff are set aside.
                found = found.map { item in
                    let own = inkLines(item.box, in: image).filter { run in
                        !staffRows.contains { $0.minY < run.maxY && run.minY < $0.maxY }
                            && !glyphs.contains { glyph in
                                let overlap = min(glyph.maxX, item.box.maxX) - max(glyph.minX, item.box.minX)
                                return overlap > item.box.width * 0.5 && glyph.minY < run.midY && run.midY < glyph.maxY
                            }
                    }
                    guard let top = own.map(\.minY).min(), let bottom = own.map(\.maxY).max(),
                          bottom - top > item.box.height * 0.25 else { return item }
                    let margin = (bottom - top) * 0.12
                    let tight = CGRect(x: item.box.minX, y: top - margin, width: item.box.width,
                                       height: bottom - top + margin * 2).intersection(item.box)
                    guard !tight.isNull, tight.height < item.box.height * 0.9 else { return item }
                    return Found(original: item.original, box: tight, confidence: item.confidence)
                }
                // A box still taller than the chords beside it — its letters
                // touch the lyric above, so no blank row parts them — takes
                // the height of its row.
                let tightened = found
                found = tightened.map { item in
                    let peers = tightened.filter { peer in
                        peer.id != item.id && peer.box.height < item.box.height * 0.7
                            && item.box.minY < peer.box.midY && peer.box.midY < item.box.maxY
                    }
                    guard peers.count >= 2,
                          let top = median(peers.map(\.box.minY)), let bottom = median(peers.map(\.box.maxY)),
                          bottom > top else { return item }
                    return Found(original: item.original,
                                 box: CGRect(x: item.box.minX, y: top, width: item.box.width, height: bottom - top),
                                 confidence: item.confidence)
                }
            }
            // Nor anything at the very start of a staff, over the clef: that
            // is where the measure number goes, and an italic 「27」 read as
            // 「A」. A system's first chord sits over its first note, clear
            // of the clef by more than two line-gaps.
            for staff in staves.map(\.staff) {
                guard let start = staffStart(staff, in: image) else { continue }
                let gap = staff.height / 4
                let gapX = gap * CGFloat(image.height) / CGFloat(image.width)
                found.removeAll { item in
                    item.box.midY > staff.minY - gap * 7 && item.box.midY < staff.minY + gap
                        && item.box.minX < start + gapX * 2
                }
            }
            // Chords sit ABOVE a staff. Anything centred between its lines
            // is notation: on the iPhone the key signature's ♯, on the top
            // line, was read as 「F」 and became a chord at every staff.
            found.removeAll { item in
                staves.contains { $0.staff.minY < item.box.midY && item.box.midY < $0.staff.maxY }
            }
            // The same sharp, read with its box cut off at the top line: by
            // its box it sits above the staff. By its ink it runs through
            // the line — but so does a note stem rising under the first
            // chord of a row, and testing that alone removed real chords.
            // What only a key signature does is repeat: the same columns
            // run through the top line of nearly EVERY staff on the page.
            found.removeAll { item in
                guard item.box.minX < 0.13 else { return false }
                // Probed where the letters are — the inked columns of the
                // box's upper part, middle half. A chord printed just right
                // of the signature can come back in one box with the ♯'s
                // top, and probing the whole box took the ♯ for the chord.
                let letters = letterColumns(item.box, in: image)
                let hits = staves.filter { staff in
                    let probe = CGRect(x: letters.midX - letters.width / 4,
                                       y: staff.staff.minY - staff.staff.height * 0.3,
                                       width: letters.width / 2, height: staff.staff.height * 0.25)
                    return runsIntoStaff(probe, staff: staff.staff, in: image)
                }.count
                return Double(hits) >= Double(staves.count) * 0.8
            }
        }

        return found.sorted {
            abs($0.box.minY - $1.box.minY) > 0.01 ? $0.box.minY < $1.box.minY
                                                   : $0.box.minX < $1.box.minX
        }
    }

    /// Chords read from the ink on each chord line that nothing covers yet.
    private static func unreadBlobs(in image: CGImage, around found: [Found]) -> [Found] {
        var out: [Found] = []
        for line in chordLines(found) {
            let h = line.maxY - line.minY
            let band = CGRect(x: 0, y: line.minY - h * 0.2, width: 1, height: h * 1.4)
            let pixels = CGRect(x: 0, y: band.minY * CGFloat(image.height),
                                width: CGFloat(image.width),
                                height: band.height * CGFloat(image.height)).integral
            guard let strip = image.cropping(to: pixels),
                  let ink = columnInk(strip) else { continue }

            // Words are ink separated by a gap wider than a letter gap.
            let gap = max(4, Int(Double(strip.height) * 0.35))
            for segment in segments(ink, minimumGap: gap) {
                let x0 = CGFloat(segment.lowerBound) / CGFloat(image.width)
                let x1 = CGFloat(segment.upperBound) / CGFloat(image.width)
                let covered = line.items.contains { $0.box.maxX > x0 && $0.box.minX < x1 }
                guard !covered else { continue }

                let pad = strip.height / 2
                let rect = CGRect(x: max(0, segment.lowerBound - pad), y: 0,
                                  width: min(strip.width, segment.upperBound + pad) - max(0, segment.lowerBound - pad),
                                  height: strip.height)
                guard let piece = strip.cropping(to: rect),
                      let alone = padded(piece, margin: strip.height, scale: 3) else { continue }
                var read = recognise(alone, languages: ["en-US"]).chords
                    + recognise(alone, languages: ["ko-KR", "en-US"]).chords
                if read.isEmpty, let echoed = readRepeated(piece) { read = [echoed] }
                guard let chord = read.first else { continue }
                out.append(Found(
                    original: chord.original,
                    box: CGRect(x: x0, y: band.minY + band.height * 0.15,
                                width: x1 - x0, height: band.height * 0.7),
                    confidence: chord.confidence))
            }
        }
        return out
    }

    /// The image scaled up, smoothly, for a second look at small text.
    static func enlarged(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor, height = image.height * factor
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Strips just above each five-line staff, normalised — where a lead
    /// sheet prints its chords.
    static func staffBands(in image: CGImage) -> [CGRect] {
        staves(in: image).map(\.band)
    }

    /// Each five-line staff on the page — its lines, top to bottom — and
    /// the strip above it where its chords sit. Normalised.
    static func staves(in image: CGImage) -> [(band: CGRect, staff: CGRect)] {
        guard let gray = grayscale(image) else { return [] }
        let width = image.width, height = image.height

        // Rows that are mostly ink across the page: staff lines. Counted
        // at a light threshold — staff lines are drawn thin and grey, and
        // anti-aliasing spreads one over two pixel rows at half strength.
        var lineRows: [Int] = []
        for y in 0..<height {
            var inked = 0
            let row = y * width
            for x in 0..<width where gray[row + x] < 200 { inked += 1 }
            if inked > width / 2 { lineRows.append(y) }
        }
        // Consecutive rows are one line.
        var lines: [CGFloat] = []
        var run: [Int] = []
        for y in lineRows {
            if let last = run.last, y - last > 1 {
                lines.append(CGFloat(run.reduce(0, +)) / CGFloat(run.count)); run = []
            }
            run.append(y)
        }
        if !run.isEmpty { lines.append(CGFloat(run.reduce(0, +)) / CGFloat(run.count)) }

        // Five evenly spaced lines are a staff.
        var bands: [(band: CGRect, staff: CGRect)] = []
        var i = 0
        var previousBottom: CGFloat = 0
        while i + 4 < lines.count {
            let gaps = (0..<4).map { lines[i + $0 + 1] - lines[i + $0] }
            let mean = gaps.reduce(0, +) / 4
            if mean > 2, gaps.allSatisfy({ abs($0 - mean) < mean * 0.3 }) {
                let top = lines[i]
                // From well above the staff down to just above it; never
                // above the previous staff, whose notes would come along.
                // Four line-gaps: where chords sit, and short of the
                // previous staff's lyrics — which, read as Latin, turned
                // into 「A ä - d -」 and put an A on the page.
                let upper = max(previousBottom + mean, top - mean * 4)
                let lower = top - mean * 0.2
                if lower > upper {
                    let staff = CGRect(x: 0, y: top / CGFloat(height),
                                       width: 1, height: (lines[i + 4] - top) / CGFloat(height))
                    bands.append((CGRect(x: 0, y: upper / CGFloat(height),
                                         width: 1, height: (lower - upper) / CGFloat(height)), staff))
                }
                previousBottom = lines[i + 4]
                i += 5
            } else {
                i += 1
            }
        }
        return bands
    }

    /// Every separate word of ink in a strip, read on its own.
    ///
    /// Long horizontal strokes — a volta bracket, a tie — are taken out
    /// first, or they join every chord under them into one word; and note
    /// stems rising from below, which change what a letter reads as.
    private static func readWordsAlone(in image: CGImage, band: CGRect) -> [Found] {
        let pixels = CGRect(x: 0, y: band.minY * CGFloat(image.height),
                            width: CGFloat(image.width),
                            height: band.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: pixels) else { return [] }
        let width = crop.width, height = crop.height
        var gray = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(
            data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Erase long horizontal runs.
        let longRun = max(height * 2, width / 25)
        for y in 0..<height {
            var x = 0
            while x < width {
                guard gray[y * width + x] < 160 else { x += 1; continue }
                var end = x
                while end < width, gray[y * width + end] < 160 { end += 1 }
                if end - x >= longRun { for i in x..<end { gray[y * width + i] = 255 } }
                x = end
            }
        }
        // Erase note stems: thin strokes that cross the strip's bottom edge
        // from the staff below. One rising into the opening of a 「C」 made
        // it a 「G」 — 「C♯m」 read as 「G#m」 on a hymn page.
        if let page = grayscale(image) {
            let below = Int(pixels.maxY) + 1
            let stemWidth = max(2, height / 8)
            var x = 0
            while x < width {
                func crosses(_ x: Int) -> Bool {
                    below < image.height && gray[(height - 1) * width + x] < 160
                        && page[below * image.width + x] < 160
                }
                guard crosses(x) else { x += 1; continue }
                var end = x
                while end < width, crosses(end) { end += 1 }
                if end - x <= stemWidth {
                    for column in x..<end {
                        var y = height - 1
                        while y >= 0, gray[y * width + column] < 160 { gray[y * width + column] = 255; y -= 1 }
                    }
                }
                x = end
            }
        }
        guard let cleaned = context.makeImage() else { return [] }

        var ink = [Int](repeating: 0, count: width)
        for y in 0..<height { for x in 0..<width where gray[y * width + x] < 160 { ink[x] += 1 } }
        let gap = max(3, Int(Double(height) * 0.18))

        var out: [Found] = []
        // A segment thinner than a letter is a stem or a barline.
        for segment in segments(ink, minimumGap: gap) where segment.count >= max(3, height / 4) {
            let pad = height / 3
            let x0 = max(0, segment.lowerBound - pad), x1 = min(width, segment.upperBound + pad)
            guard let piece = cleaned.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: height)),
                  let ready = padded(piece, margin: height / 2, scale: 3) else { continue }
            var read = recognise(ready, languages: ["en-US"], strict: true).chords
            if read.isEmpty, let echoed = readRepeated(piece) { read = [echoed] }
            guard let chord = read.max(by: { $0.original.count < $1.original.count }) else { continue }
            // Where the ink is, vertically, in the strip.
            var top = height, bottom = 0
            for y in 0..<height {
                for x in segment where gray[y * width + x] < 160 { top = min(top, y); bottom = max(bottom, y); break }
            }
            guard bottom > top else { continue }
            out.append(Found(
                original: chord.original,
                box: CGRect(x: CGFloat(segment.lowerBound) / CGFloat(image.width),
                            y: band.minY + band.height * CGFloat(top) / CGFloat(height),
                            width: CGFloat(segment.count) / CGFloat(image.width),
                            height: band.height * CGFloat(bottom - top) / CGFloat(height)),
                confidence: chord.confidence))
        }
        return out
    }

    /// Whether a found symbol sits inside a drawn box — a rehearsal mark.
    private static func isBoxed(_ box: CGRect, in image: CGImage) -> Bool {
        guard let gray = grayscale(image) else { return false }
        let w = image.width, h = image.height
        let pad = box.height * 0.45
        let r = CGRect(x: (box.minX - pad * 0.6) * CGFloat(w), y: (box.minY - pad) * CGFloat(h),
                       width: (box.width + pad * 1.2) * CGFloat(w), height: (box.height + pad * 2) * CGFloat(h))
        let x0 = max(0, Int(r.minX)), x1 = min(w - 1, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(h - 1, Int(r.maxY))
        guard x1 - x0 > 4, y1 - y0 > 4 else { return false }
        // A side counts as drawn when a line of ink runs most of its length
        // within a few pixels of it.
        func side(_ points: [(Int, Int)]) -> Bool {
            let inked = points.filter { gray[$0.1 * w + $0.0] < 140 }.count
            return Double(inked) / Double(max(points.count, 1)) > 0.7
        }
        func horizontal(near y: Int) -> Bool {
            (max(0, y - 3)...min(h - 1, y + 3)).contains { yy in side((x0...x1).map { ($0, yy) }) }
        }
        func vertical(near x: Int) -> Bool {
            (max(0, x - 3)...min(w - 1, x + 3)).contains { xx in side((y0...y1).map { (xx, $0) }) }
        }
        return horizontal(near: y0) && horizontal(near: y1) && vertical(near: x0) && vertical(near: x1)
    }

    /// The span of a box's columns holding ink in its upper 60% — where a
    /// chord's letters are, and what pokes up from below is not.
    /// Each line of ink inside a box, top to bottom — rows with ink, split
    /// where blank rows part them — as its top and bottom heights.
    static func inkLines(_ box: CGRect, in image: CGImage) -> [(minY: CGFloat, maxY: CGFloat, midY: CGFloat)] {
        guard let gray = grayscale(image) else { return [] }
        let w = image.width, h = image.height
        let x0 = max(0, Int(box.minX * CGFloat(w))), x1 = min(w - 1, Int(box.maxX * CGFloat(w)))
        let y0 = max(0, Int(box.minY * CGFloat(h))), y1 = min(h - 1, Int(box.maxY * CGFloat(h)))
        guard x1 > x0, y1 > y0 else { return [] }
        var lines: [(minY: CGFloat, maxY: CGFloat, midY: CGFloat)] = []
        var start: Int?
        for y in y0...(y1 + 1) {
            let inked = y <= y1 && (x0...x1).contains { gray[y * w + $0] < 128 }
            if inked, start == nil { start = y }
            if !inked, let s = start {
                lines.append((CGFloat(s) / CGFloat(h), CGFloat(y) / CGFloat(h), CGFloat(s + y) / 2 / CGFloat(h)))
                start = nil
            }
        }
        return lines
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    static func letterColumns(_ box: CGRect, in image: CGImage) -> CGRect {
        guard let gray = grayscale(image) else { return box }
        let w = image.width, h = image.height
        let x0 = max(0, Int(box.minX * CGFloat(w))), x1 = min(w - 1, Int(box.maxX * CGFloat(w)))
        let y0 = max(0, Int(box.minY * CGFloat(h))), y1 = min(h - 1, Int((box.minY + box.height * 0.6) * CGFloat(h)))
        guard x1 > x0, y1 > y0 else { return box }
        let inked = (x0...x1).filter { x in (y0...y1).contains { gray[$0 * w + x] < 128 } }
        guard let first = inked.first, let last = inked.last else { return box }
        return CGRect(x: CGFloat(first) / CGFloat(w), y: box.minY,
                      width: CGFloat(last - first + 1) / CGFloat(w), height: box.height)
    }

    /// Where a staff begins across the page: the left end of the longest
    /// stretch where at least three of its five lines are inked.
    static func staffStart(_ staff: CGRect, in image: CGImage) -> CGFloat? {
        guard let gray = grayscale(image) else { return nil }
        let w = image.width, h = image.height
        let top = staff.minY * CGFloat(h), gap = staff.height * CGFloat(h) / 4
        let rows = (0..<5).map { Int((top + gap * CGFloat($0)).rounded()) }
        func onStaff(_ x: Int) -> Bool {
            rows.filter { y in (y - 1...y + 1).contains { $0 >= 0 && $0 < h && gray[$0 * w + x] < 200 } }.count >= 3
        }
        var best = (start: 0, length: 0), runStart = -1, missed = 0
        for x in 0...w {
            if x < w, onStaff(x) {
                if runStart < 0 { runStart = x }
                missed = 0
            } else if runStart >= 0 {
                missed += 1
                if missed > 3 || x == w {
                    let length = x - missed + 1 - runStart
                    if length > best.length { best = (runStart, length) }
                    runStart = -1; missed = 0
                }
            }
        }
        guard best.length > w / 4 else { return nil }
        return CGFloat(best.start) / CGFloat(w)
    }

    /// Whether the ink under a chord's box carries on, unbroken, from above
    /// a staff's top line to below it — a key-signature ♯ or ♭ does; a
    /// chord, printed above the staff with white under it, does not.
    static func runsIntoStaff(_ box: CGRect, staff: CGRect, in image: CGImage) -> Bool {
        guard let gray = grayscale(image) else { return false }
        let w = image.width, h = image.height
        let gap = staff.height / 4
        // Only a box that ends near this staff's top line.
        guard box.maxY > staff.minY - gap * 1.5, box.minY < staff.minY else { return false }
        let line = Int(staff.minY * CGFloat(h))
        let y0 = max(0, Int((staff.minY - gap * 0.4) * CGFloat(h)))
        let y1 = min(h - 1, Int((staff.minY + gap * 0.8) * CGFloat(h)))
        let x0 = max(0, Int(box.minX * CGFloat(w))), x1 = min(w - 1, Int(box.maxX * CGFloat(w)))
        guard y1 - y0 > 4, x1 > x0 else { return false }
        var rows = 0, inked = 0
        for y in y0...y1 where abs(y - line) > 2 {
            rows += 1
            if (x0...x1).contains(where: { gray[y * w + $0] < 128 }) { inked += 1 }
        }
        return rows > 0 && Double(inked) / Double(rows) >= 0.9
    }

    /// The last page's pixels, read many times per page. Keyed by the image
    /// itself, held: keyed by its address, a freed page's address was
    /// reused by the next one and handed back the old page's pixels — no
    /// staves found on a page full of them.
    private static var grayCache: (image: CGImage, pixels: [UInt8])?
    /// Two charts can be read at once — the one on the stand and the rest
    /// of a set being exported.
    private static let grayLock = NSLock()

    static func grayscale(_ image: CGImage) -> [UInt8]? {
        grayLock.lock()
        let cached = grayCache
        grayLock.unlock()
        if let cached, cached.image === image { return cached.pixels }
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(
            data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        grayLock.lock(); grayCache = (image, gray); grayLock.unlock()
        return gray
    }

    private struct ChordLine { var items: [Found]; var minY: CGFloat; var maxY: CGFloat }

    /// Found chords grouped into lines by vertical overlap.
    private static func chordLines(_ found: [Found]) -> [ChordLine] {
        var lines: [ChordLine] = []
        for item in found.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let index = lines.lastIndex(where: { item.box.midY > $0.minY && item.box.midY < $0.maxY }) {
                lines[index].items.append(item)
                lines[index].minY = min(lines[index].minY, item.box.minY)
                lines[index].maxY = max(lines[index].maxY, item.box.maxY)
            } else {
                lines.append(ChordLine(items: [item], minY: item.box.minY, maxY: item.box.maxY))
            }
        }
        return lines
    }

    /// How many dark pixels each column of an image holds.
    private static func columnInk(_ image: CGImage) -> [Int]? {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(
            data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var ink = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where gray[row + x] < 128 { ink[x] += 1 }
        }
        return ink
    }

    /// Runs of inked columns, joined across gaps narrower than `minimumGap`.
    private static func segments(_ ink: [Int], minimumGap: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        var lastInk = -minimumGap - 1
        for (x, count) in ink.enumerated() where count > 0 {
            if let s = start, x - lastInk > minimumGap {
                out.append(s..<(lastInk + 1))
                start = x
            } else if start == nil {
                start = x
            }
            lastInk = x
        }
        if let s = start { out.append(s..<(lastInk + 1)) }
        return out
    }

    /// The image enlarged and set on a white margin, the way a single
    /// symbol is easiest to read.
    /// The lines at the top of a page, largest type first: where a chart
    /// names its song. For splitting a 콘티 file onto the 순서.
    static func titleLines(in image: CGImage) -> [String] {
        let top = CGRect(x: 0, y: 0, width: image.width, height: image.height * 35 / 100)
        guard let crop = image.cropping(to: top) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.minimumTextHeight = 0
        do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request]) } catch { return [] }
        return (request.results ?? [])
            .compactMap { observation -> (String, CGFloat)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                // A chord line is no title.
                let words = text.split(separator: " ").map(String.init)
                if !words.isEmpty, words.allSatisfy({ ScoreChordText.parse(repairedChordWord($0)) != nil }) { return nil }
                // Nor a tempo mark or a row of symbols — 「♩= 68」 read as
                // 「68111/777」: a title is mostly letters.
                let letters = text.filter(\.isLetter).count
                guard letters >= 2, Double(letters) / Double(max(text.filter { !$0.isWhitespace }.count, 1)) >= 0.6
                else { return nil }
                return (text, observation.boundingBox.height)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// A lone glyph read by showing it three times: 「F F F」.
    ///
    /// Vision reads words, and a single capital with nothing beside it —
    /// the 「F」 that opens a bar — often comes back as nothing at all, in
    /// either language, at any size. Three copies in a row are a line of
    /// text, and it reads them. Accepted only when the copies agree.
    static func readRepeated(_ piece: CGImage) -> Found? {
        let gap = max(4, piece.height / 2)
        let margin = piece.height
        let scale = 3
        let width = (piece.width * 3 + gap * 2 + margin * 2) * scale
        let height = (piece.height + margin * 2) * scale
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for copy in 0..<3 {
            let x = (margin + copy * (piece.width + gap)) * scale
            context.draw(piece, in: CGRect(x: x, y: margin * scale,
                                           width: piece.width * scale, height: piece.height * scale))
        }
        guard let image = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        var words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .flatMap { $0.split(separator: " ").map(String.init) }
            .map(repairedChordWord)
        // Read run together — 「CCC」 — the copies are still three.
        if words.count == 1, let only = words.first, only.count % 3 == 0, only.count >= 3 {
            let third = only.count / 3
            let pieces = (0..<3).map { String(only.dropFirst($0 * third).prefix(third)) }
            if Set(pieces).count == 1 { words = pieces }
        }
        guard words.count >= 2, let first = words.first,
              words.filter({ $0 == first }).count >= 2,
              ScoreChordText.parse(first) != nil else { return nil }
        return Found(original: first, box: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.5)
    }

    private static func padded(_ image: CGImage, margin: Int, scale: Int) -> CGImage? {
        let width = (image.width + margin * 2) * scale
        let height = (image.height + margin * 2) * scale
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: margin * scale, y: margin * scale,
                                       width: image.width * scale, height: image.height * scale))
        return context.makeImage()
    }

    /// One recognition pass: the chords it read, and the lines of Hangul,
    /// which mark where lyrics are and so where chords should be above.
    private static func recognise(_ image: CGImage, languages: [String],
                                  strict: Bool = false) -> (chords: [Found], lyricLines: [CGRect], koreanWords: [CGRect]) {
        let request = VNRecognizeTextRequest()
        // Accurate, not fast: chord symbols are small and this runs once
        // per page rather than per frame.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // "Am" must not become "An"
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return ([], [], []) }

        var chords: [Found] = []
        var lyrics: [CGRect] = []
        var korean: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                let b = observation.boundingBox
                lyrics.append(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
            let words = wordRanges(in: text)
            // Words of a line that is mostly Hangul, with two syllables or
            // more. A chord row read through Korean eyes picks up a stray
            // syllable — 「Em D9태」 — and judged word by word, 「태」 alone
            // was a lyric sitting on D9/F#, which was then dropped.
            let lineLetters = text.filter(\.isLetter)
            let lineHangul = lineLetters.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
            let lyricLine = lineHangul >= 2 && Double(lineHangul) >= Double(lineLetters.count) * 0.6
            for range in words where lyricLine {
                let letters = text[range].filter(\.isLetter)
                let hangul = letters.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                guard hangul > 0, Double(hangul) >= Double(letters.count) * 0.6 else { continue }
                if let b = (try? candidate.boundingBox(for: range))?.boundingBox {
                    korean.append(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
                }
            }
            // Reading one word cut out on its own, the whole read must be
            // that one chord. 「: C」 from a cut-out slur is not a C.
            if strict, words.count != 1 { continue }
            // Judged after repair: 「DIE」 is D/E and 「11.G」 is G, and the
            // checks below took them for an English word and for noise.
            let repaired = words.map { repairedChordWord(String(text[$0])) }
            // A phrase, not a chord line: 「Go to A」 — the A is a word
            // there. A Latin word of two letters or more that is not a
            // chord means the line is prose.
            let prose = repaired.contains { raw in
                let word = raw.trimmingCharacters(in: .punctuationCharacters)
                return word.count >= 2 && word.allSatisfy(\.isLetter)
                    && word.unicodeScalars.allSatisfy { $0.isASCII }
                    && ScoreChordText.parse(word) == nil
                    && !["intro", "outro", "ending", "verse", "chorus", "bridge", "coda"].contains(word.lowercased())
            }
            if prose { continue }
            // A garbled line — 「A ä - d -」, Korean read as Latin — may
            // still contain a token that parses as a lone letter. On such a
            // line a single letter is noise, not a chord.
            let garbled = repaired.contains { word in
                ScoreChordText.parse(word) == nil && word.contains { $0.isLetter }
            }
            for (range, fixed) in zip(words, repaired) {
                var word = fixed
                // A lone lowercase letter standing on its own is a chord
                // Vision has lowered — "c" for C — since a Korean chart
                // has no English one-letter words. Never "b", which is a
                // flat sign as often as anything.
                if words.count == 1, word.count == 1, "acdefg".contains(word) {
                    word = word.uppercased()
                }
                guard ScoreChordText.parse(word) != nil else { continue }
                if garbled, word.count == 1 { continue }
                let box = (try? candidate.boundingBox(for: range))?.boundingBox
                    ?? estimatedBox(of: range, in: text, line: observation.boundingBox)
                chords.append(Found(
                    original: word,
                    // Vision's origin is bottom-left; flip it so the box
                    // can be drawn straight onto the image.
                    box: CGRect(x: box.minX, y: 1 - box.maxY,
                                width: box.width, height: box.height),
                    confidence: candidate.confidence))
            }
        }
        return (chords, lyrics, korean)
    }

    /// What OCR does to chord symbols on a lead sheet, undone:
    ///
    /// - a volta or its bracket in front — 「1.G」, 「11.G」, 「||2.G」,
    ///   「I3.G」 — or a stray dash, 「-D/E」;
    /// - the slash read as an I, l or | — 「DIE」 for D/E;
    /// - F♯ read as E♯ — the F's lower bar taken for an E's. E♯ and B♯
    ///   are spellings no worship chart uses, so a chord written that way
    ///   is a misreading, and F♯ / C♯ are what was printed.
    ///
    /// Measured on a real lead sheet: these alone were five of the missed
    /// chords on one page.
    static func repairedChordWord(_ raw: String) -> String {
        var word = raw
        if let match = word.range(of: #"^(?:[|Il1]*\d*\.|[-–|])+(?=[A-G])"#, options: .regularExpression) {
            word.removeSubrange(match)
        }
        if word.range(of: #"^[A-G][#b]?(?:m|maj|sus|add|dim|aug|\d)*[Il|][A-G][#b]?$"#,
                      options: .regularExpression) != nil,
           let bar = word.lastIndex(where: { "Il|".contains($0) }) {
            word.replaceSubrange(bar...bar, with: "/")
        }
        word = word.replacingOccurrences(of: "E#", with: "F#").replacingOccurrences(of: "B#", with: "C#")
        return word
    }

    /// Adds what is new, by position: a box whose centre falls inside one
    /// already found is the same chord read again.
    private static func merge(_ incoming: [Found], into found: inout [Found]) {
        for item in incoming {
            let centre = CGPoint(x: item.box.midX, y: item.box.midY)
            let duplicate = found.contains { existing in
                existing.box.insetBy(dx: -0.004, dy: -0.004).contains(centre)
                    || item.box.contains(CGPoint(x: existing.box.midX, y: existing.box.midY))
            }
            if !duplicate { found.append(item) }
        }
    }

    /// Horizontal strips worth a second look, in normalised page space.
    private static func bands(chords: [Found], lyricLines: [CGRect]) -> [CGRect] {
        var strips: [CGRect] = []
        for chord in chords {
            let h = chord.box.height
            strips.append(CGRect(x: 0, y: chord.box.minY - h * 0.8,
                                 width: 1, height: h * 2.6))
        }
        for line in lyricLines {
            let h = line.height
            strips.append(CGRect(x: 0, y: line.minY - h * 1.7,
                                 width: 1, height: h * 1.9))
        }
        // Merge overlapping strips so one chord line is read once.
        let sorted = strips
            .map { $0.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            .filter { !$0.isNull && $0.height > 0 }
            .sorted { $0.minY < $1.minY }
        var merged: [CGRect] = []
        for strip in sorted {
            if let last = merged.last, strip.minY < last.maxY - last.height * 0.3 {
                merged[merged.count - 1] = last.union(strip)
            } else {
                merged.append(strip)
            }
        }
        return merged
    }

    /// Ranges of the space-separated words in a line.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == " " {
                if let s = start { out.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let s = start { out.append(s..<text.endIndex) }
        return out
    }

    /// The fallback when Vision has no box for a range: the word's share of
    /// the line by character count.
    private static func estimatedBox(of range: Range<String.Index>,
                                     in text: String,
                                     line: CGRect) -> CGRect {
        let total = CGFloat(max(text.count, 1))
        let from = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound)) / total
        let width = CGFloat(text.distance(from: range.lowerBound, to: range.upperBound)) / total
        return CGRect(x: line.minX + line.width * from, y: line.minY,
                      width: line.width * width, height: line.height)
    }

    // MARK: - Key

    /// The semitones from the key a score is written in to the key the team
    /// plays it in, or nil when either cannot be told.
    ///
    /// The score's key is estimated as its most common chord root, which
    /// is right for the ordinary worship song and wrong for one that lives
    /// on its IV chord — so the result is shown as a starting point the
    /// reader can see and change, never applied silently.
    ///
    /// The shift is kept within −5…+6: G to F is −2, not +10, because a
    /// chart moved ten steps up reads the same and a person thinks of it as
    /// two down.
    static func shift(fromScoreChords symbols: [String], toKey teamKey: String?) -> Int? {
        ScoreChordText.likelyRoot(of: symbols).flatMap { shift(fromRoot: $0, toKey: teamKey) }
    }

    /// The same, from a chart key already known — read from the file name,
    /// say — as a relative-major root.
    static func shift(fromRoot source: Int, toKey teamKey: String?) -> Int? {
        guard let teamKey, var target = keyRoot(teamKey) else { return nil }
        // likelyRoot answers in major; a minor team key is compared as its
        // relative major — 「Em」 means the chart should sound in G's chords.
        if isMinorKey(teamKey) { target = (target + 3) % 12 }
        var shift = ((target - source) % 12 + 12) % 12
        if shift > 6 { shift -= 12 }
        return shift
    }

    /// Whether a key as typed names a minor key: 「Em」, 「F#m」, 「C minor」.
    static func isMinorKey(_ raw: String) -> Bool {
        let first = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "키", with: "").split(separator: " ")
        guard let token = first.first else { return false }
        if first.count > 1, ["minor", "min", "단조"].contains(first[1].lowercased()) { return true }
        return token.count > 1 && token.hasSuffix("m")
    }

    /// The root of a key as a leader types it — "A", "Bb", "F#m", "E major",
    /// "D키" — or nil.
    static func keyRoot(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "키", with: "")
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        guard let first = cleaned.split(separator: " ").first else { return nil }
        var token = String(first)
        // "F#m" names a minor key, whose chords are spelled from F#.
        if token.count > 1, token.hasSuffix("m") { token.removeLast() }
        return ScoreChordText.parse(token).flatMap { $0.suffix.isEmpty ? $0.root : nil }
    }
}
