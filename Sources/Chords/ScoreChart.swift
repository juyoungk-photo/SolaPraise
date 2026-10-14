//
//  ScoreChart.swift
//  SolaPraise
//
//  A score page read as a CHART: its bars, the chords in each bar, and the
//  lyrics under them — not the notes. For the stand's 코드표, where a song
//  is read as rows of bars with each chord over the syllable it falls on.
//
//  WHY NOT JUST THE PAGE: a lead sheet spends most of its ink on notes a
//  guitarist or keyboard player does not read. Chords and words, laid out
//  bar by bar, are what the band actually plays from — and, unlike the
//  page, they reflow to a phone's width and stay large.
//
//  What is read, and how:
//  - Staves, by their five lines (ScoreRecognition.staves).
//  - Barlines: a stroke that covers the staff from top line to bottom line
//    and stops there. Note stems are shorter, or run on above or below.
//    Thick strokes and repeat dots mark repeats.
//  - Chords: the ones already found, placed in the bar under which they
//    start — by id, so a reader's corrections and the transposition carry.
//  - Lyrics: the lines of text between a staff and the next one, top to
//    bottom one line per verse, each syllable under the chord it follows.
//
//  The lyrics are read from the team's own chart, on the device, to lay
//  that chart out. They are never stored on the sheet or in Drive.
//
//  Limits, stated so the UI can: a grand staff (piano) reads as two rows,
//  the lower one empty; repeats are marked but not unfolded; volta numbers
//  and D.S./Coda are not read yet.
//

import Foundation
import CoreGraphics
import Vision

enum ScoreChart {

    /// One chord as the chart needs it: which, and where on the page.
    /// Raised whenever the reading changes what it returns, so a 코드표
    /// kept on the device from an older reading is read again.
    static let version = 1

    struct ChordMark {
        let id: UUID
        /// Normalised, origin top-left.
        let box: CGRect
    }

    struct Segment: Equatable, Codable {
        /// The chord this segment starts with; nil for words before the
        /// first chord of a bar.
        var chord: UUID?
        /// One entry per verse line under this staff, "" where a verse has
        /// no words here.
        var lyrics: [String]
    }

    /// One sung position — a syllable column — with the chord that starts
    /// there, if any. The same column across verses holds each verse's
    /// syllable for that note, as in a hymnal.
    struct Cell: Equatable, Codable {
        var chord: UUID?
        /// One per verse line, "" where a verse has none here.
        var syllables: [String]
        /// Per verse: the syllable is held — printed with a dash after it.
        var held: [Bool] = []

        func isHeld(_ verse: Int) -> Bool { held.indices.contains(verse) && held[verse] }
    }

    struct Bar: Equatable, Codable {
        var segments: [Segment]
        var repeatStart = false
        var repeatEnd = false
        /// The bar note by note, for laying lyrics out as lines.
        var cells: [Cell] = []

        var hasChord: Bool { segments.contains { $0.chord != nil } }
    }

    struct System: Equatable, Codable {
        var bars: [Bar]
        /// How many verse lines were read under this staff.
        var verses: Int
    }

    // MARK: - Reading

    static func read(_ image: CGImage, chords: [ChordMark]) -> [System] {
        let staves = ScoreRecognition.staves(in: image)
        guard !staves.isEmpty else { return [] }
        let words = lyricWords(in: image, staves: staves.map(\.staff), chords: chords.map(\.box))
        let height = CGFloat(image.height), width = CGFloat(image.width)

        return staves.enumerated().map { index, staff in
            let gap = staff.staff.height / 4
            // The same gap measured across the page rather than down it.
            let gapX = gap * height / width
            let measured = barlines(in: image, staff: staff.staff)

            // Chords above this staff: below the previous staff, and close
            // enough above this one to be its chords.
            let floor = index > 0 ? staves[index - 1].staff.maxY : 0
            let mine = chords.filter {
                $0.box.midY < staff.staff.minY + gap
                    && $0.box.midY > max(floor, staff.staff.minY - gap * 7)
            }
            .sorted { $0.box.minX < $1.box.minX }

            // Words under it, grouped into verse lines top to bottom.
            let ceiling = index + 1 < staves.count ? staves[index + 1].staff.minY - gap : 1
            let under = words.filter { $0.box.midY > staff.staff.maxY && $0.box.midY < ceiling }
            let lines = verseLines(under)

            // Bars from the barlines; a staff with none is one bar.
            var edges: [CGFloat] = [measured.start]
            var startRepeat: Set<Int> = [], endRepeat: Set<Int> = []
            for line in measured.lines {
                if line.x - (edges.last ?? 0) > gapX * 1.5 {
                    edges.append(line.x)
                } else if let last = edges.indices.last {
                    edges[last] = line.x
                }
                if line.repeatEnd { endRepeat.insert(edges.count - 2) }
                if line.repeatStart { startRepeat.insert(edges.count - 1) }
            }
            if measured.end - (edges.last ?? 0) > gapX * 1.5 {
                edges.append(measured.end)
            }

            var bars: [Bar] = []
            for b in 0..<max(edges.count - 1, 0) {
                let left = edges[b], right = edges[b + 1]
                let isLast = b == edges.count - 2
                // A chord belongs to the bar its first letter sits in;
                // one just past the last barline still belongs to the last.
                let inBar = mine.filter {
                    let x = $0.box.minX + min($0.box.width * 0.3, gapX * 0.5)
                    return (b == 0 ? true : x >= left) && (isLast ? true : x < right)
                }
                let barWords = lines.map { line in
                    line.filter { $0.box.midX >= (b == 0 ? 0 : left) && (isLast || $0.box.midX < right) }
                }
                bars.append(Bar(segments: segments(chords: inBar, words: barWords),
                                repeatStart: startRepeat.contains(b),
                                repeatEnd: endRepeat.contains(b),
                                cells: cells(chords: inBar, words: barWords)))
            }
            // The stretch before the first barline that holds only the clef,
            // key and time — no chord, no word, shorter than a bar — is not
            // a bar. A pickup with words under it stays.
            if bars.count > 1, let first = bars.first, !first.hasChord,
               first.segments.allSatisfy({ $0.lyrics.allSatisfy(\.isEmpty) }) {
                let widths = (1..<edges.count - 1).map { edges[$0 + 1] - edges[$0] }.sorted()
                if edges[1] - edges[0] < widths[widths.count / 2] * 0.6 {
                    bars[1].repeatStart = bars[1].repeatStart || first.repeatStart
                    bars.removeFirst()
                }
            }
            if bars.isEmpty {
                bars = [Bar(segments: segments(chords: mine, words: lines),
                            cells: cells(chords: mine, words: lines))]
            }
            return System(bars: bars, verses: lines.count)
        }
    }

    /// A bar's words split at its chords: each chord with the syllables
    /// from it up to the next chord.
    private static func segments(chords: [ChordMark], words: [[Word]]) -> [Segment] {
        let starts = chords.map(\.box.minX)
        var out: [Segment] = []
        // Words before the first chord.
        let lead = words.map { line in line.filter { starts.isEmpty || $0.box.midX < starts[0] - 0.004 } }
        if lead.contains(where: { !$0.isEmpty }) || chords.isEmpty {
            out.append(Segment(chord: nil, lyrics: lead.map(joined)))
        }
        for (i, chord) in chords.enumerated() {
            let from = chord.box.minX - 0.004
            let to = i + 1 < chords.count ? starts[i + 1] - 0.004 : .greatestFiniteMagnitude
            let mine = words.map { line in line.filter { $0.box.midX >= from && $0.box.midX < to } }
            out.append(Segment(chord: chord.id, lyrics: mine.map(joined)))
        }
        return out
    }

    /// A bar's syllables in columns, verse lines aligned by where they
    /// were printed, and each chord on the syllable it starts over. A chord
    /// with no syllable near it — an intro, a held note — is a column of
    /// its own.
    static func cells(chords: [ChordMark], words: [[Word]]) -> [Cell] {
        let verses = words.count
        struct Column {
            var minX: CGFloat; var maxX: CGFloat; var syllables: [String]; var chord: UUID?
            var held: [Bool] = []
        }
        var columns: [Column] = []
        for (verse, line) in words.enumerated() {
            var lastColumn: Int?
            for (index, word) in line.enumerated() {
                var text = word.text
                if index == 0, let number = text.range(of: #"^\d+\."#, options: .regularExpression) {
                    text.removeSubrange(number)
                }
                let dashed = text.contains { dashes.contains($0) }
                text = text.filter { !dashes.contains($0) }
                guard !text.isEmpty else {
                    // A dash standing alone holds the syllable before it.
                    if dashed, let last = lastColumn { columns[last].held[verse] = true }
                    continue
                }
                let mid = word.box.midX
                let held = word.held || (dashed && word.text.last.map { dashes.contains($0) } == true)
                if let match = columns.firstIndex(where: { column in
                    column.syllables[verse].isEmpty
                        && abs((column.minX + column.maxX) / 2 - mid) < max(column.maxX - column.minX, word.box.width) * 0.6
                }) {
                    columns[match].syllables[verse] = text
                    columns[match].held[verse] = held
                    columns[match].minX = min(columns[match].minX, word.box.minX)
                    columns[match].maxX = max(columns[match].maxX, word.box.maxX)
                    lastColumn = match
                } else {
                    var syllables = [String](repeating: "", count: verses)
                    syllables[verse] = text
                    var heldFlags = [Bool](repeating: false, count: verses)
                    heldFlags[verse] = held
                    columns.append(Column(minX: word.box.minX, maxX: word.box.maxX, syllables: syllables, held: heldFlags))
                    lastColumn = columns.count - 1
                }
            }
        }
        columns.sort { $0.minX < $1.minX }
        let typical = columns.map { $0.maxX - $0.minX }.sorted().dropFirst(columns.count / 2).first ?? 0.02
        for chord in chords.sorted(by: { $0.box.minX < $1.box.minX }) {
            let x = chord.box.minX
            let nearest = columns.indices
                .filter { columns[$0].chord == nil && columns[$0].maxX > x - typical * 0.3 }
                .min { abs(columns[$0].minX - x) < abs(columns[$1].minX - x) }
            if let nearest, abs(columns[nearest].minX - x) < typical * 1.6 {
                columns[nearest].chord = chord.id
            } else {
                let at = columns.firstIndex { $0.minX > x } ?? columns.count
                columns.insert(Column(minX: x, maxX: chord.box.maxX,
                                      syllables: [String](repeating: "", count: verses), chord: chord.id,
                                      held: [Bool](repeating: false, count: verses)), at: at)
            }
        }
        return columns.map { Cell(chord: $0.chord, syllables: $0.syllables, held: $0.held) }
    }

    // MARK: - Barlines

    struct Barline: Equatable {
        /// Normalised x of its centre.
        var x: CGFloat
        var thick: Bool
        var repeatStart: Bool
        var repeatEnd: Bool
    }

    /// Where a staff starts and ends, and the barlines across it.
    static func barlines(in image: CGImage, staff: CGRect)
        -> (start: CGFloat, end: CGFloat, lines: [Barline]) {
        guard let gray = ScoreRecognition.grayscale(image) else { return (0, 1, []) }
        let w = image.width, h = image.height
        let top = staff.minY * CGFloat(h), bottom = staff.maxY * CGFloat(h)
        let gap = (bottom - top) / 4
        func dark(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < w && y >= 0 && y < h && gray[y * w + x] < 160
        }

        // The staff's own extent: the longest stretch where at least three
        // of its five lines are inked. One line alone was not enough — a
        // grey line broken by anti-aliasing lost four staves of a page.
        let lineRows = (0..<5).map { Int((top + gap * CGFloat($0)).rounded()) }
        func onStaff(_ x: Int) -> Bool {
            lineRows.filter { y in (y - 1...y + 1).contains { x >= 0 && x < w && $0 >= 0 && $0 < h && gray[$0 * w + x] < 200 } }
                .count >= 3
        }
        var bestStart = 0, bestLength = 0, runStart = -1, missed = 0
        for x in 0...w {
            if x < w, onStaff(x) {
                if runStart < 0 { runStart = x }
                missed = 0
            } else if runStart >= 0 {
                missed += 1
                // A pixel or two of break is anti-aliasing, not the end.
                if missed > 3 || x == w {
                    let length = x - missed + 1 - runStart
                    if length > bestLength { bestLength = length; bestStart = runStart }
                    runStart = -1
                    missed = 0
                }
            }
        }
        guard bestLength > w / 4 else { return (0, 1, []) }
        let startX = bestStart, endX = bestStart + bestLength - 1

        // Columns inked from the top line to the bottom line, and not much
        // beyond either: a stem runs short, or on past the staff to its
        // beam or note; a clef sticks out both ways.
        let y0 = Int(top) + 2, y1 = Int(bottom) - 2
        guard y1 > y0 + 4 else { return (0, 1, []) }
        let aboveRows = Array(Int(top - gap * 0.9)...Int(top - gap * 0.35))
        let belowRows = Array(Int(bottom + gap * 0.35)...Int(bottom + gap * 0.9))
        // The outer spaces — top and bottom — clear of the staff lines:
        // where a stem's notehead or beam sits, and where a barline has
        // nothing beside it. A beam lying on the top line with its head in
        // the bottom space made a stem exactly as tall as a barline.
        let outerSpaces = [Int(top + gap * 0.25)...Int(top + gap * 0.75),
                           Int(bottom - gap * 0.75)...Int(bottom - gap * 0.25)]
        let side = max(2, Int(gap * 0.6))
        /// Ink beside a run of columns, in either outer space, on either side.
        func crowded(_ left: Int, _ right: Int) -> Bool {
            for rows in outerSpaces {
                for columns in [max(0, left - side)...max(0, left - 2),
                                min(w - 1, right + 2)...min(w - 1, right + side)] {
                    var inked = 0, total = 0
                    // The other half of a double barline is not a notehead.
                    for y in rows { for c in columns where !spans[c] { total += 1; if dark(c, y) { inked += 1 } } }
                    if total > 0, Double(inked) / Double(total) > 0.3 { return true }
                }
            }
            return false
        }
        var candidate = [Bool](repeating: false, count: w)
        for x in startX...endX {
            var inked = 0
            for y in y0...y1 where dark(x, y) { inked += 1 }
            guard Double(inked) >= Double(y1 - y0 + 1) * 0.94 else { continue }
            let above = aboveRows.filter { dark(x, $0) }.count
            let below = belowRows.filter { dark(x, $0) }.count
            if Double(above) <= Double(aboveRows.count) * 0.5,
               Double(below) <= Double(belowRows.count) * 0.5 {
                candidate[x] = true
            }
        }
        // Judged on the whole run, from its edges: a thick barline's own
        // ink is not its neighbour.
        let spans = candidate
        var scan = startX
        while scan <= endX {
            guard candidate[scan] else { scan += 1; continue }
            var end = scan
            while end + 1 <= endX, candidate[end + 1] { end += 1 }
            if crowded(scan, end) { for c in scan...end { candidate[c] = false } }
            scan = end + 1
        }

        // Runs of such columns; a barline is thin, or thick for a repeat or
        // an ending. Runs a gap apart are one double barline.
        var runs: [ClosedRange<Int>] = []
        var x = startX
        while x <= endX {
            guard candidate[x] else { x += 1; continue }
            var end = x
            while end + 1 <= endX, candidate[end + 1] { end += 1 }
            if CGFloat(end - x + 1) <= gap * 0.9 { runs.append(x...end) }
            x = end + 1
        }
        var groups: [[ClosedRange<Int>]] = []
        for run in runs {
            if let last = groups.last?.last, CGFloat(run.lowerBound - last.upperBound) <= gap * 1.2 {
                groups[groups.count - 1].append(run)
            } else {
                groups.append([run])
            }
        }

        // Repeat dots: two small dots in the middle two spaces, beside a
        // thick barline.
        func dots(_ columns: ClosedRange<Int>) -> Bool {
            let upper = Int(top + gap * 1.5), lower = Int(top + gap * 2.5)
            let clearA = Int(top + gap * 0.5), clearB = Int(top + gap * 3.5)
            return columns.contains { c in
                guard dark(c, upper), dark(c, lower), !dark(c, clearA), !dark(c, clearB) else { return false }
                // Small: a dot, not a notehead or a stem.
                var run = 0
                var y = upper
                while dark(c, y) { run += 1; y -= 1 }
                y = upper + 1
                while dark(c, y) { run += 1; y += 1 }
                return CGFloat(run) <= gap * 0.85
            }
        }

        let lines: [Barline] = groups.map { group in
            let left = group.first!.lowerBound, right = group.last!.upperBound
            let thick = group.contains { CGFloat($0.count) > gap * 0.32 } || group.count > 1
            let reach = Int(gap * 1.3), near = max(1, Int(gap * 0.12))
            let endsRepeat = thick && dots(max(startX, left - reach)...max(startX, left - near))
            let startsRepeat = thick && dots(min(endX, right + near)...min(endX, right + reach))
            return Barline(x: CGFloat(left + right) / 2 / CGFloat(w), thick: thick,
                           repeatStart: startsRepeat, repeatEnd: endsRepeat)
        }
        return (CGFloat(startX) / CGFloat(w), CGFloat(endX) / CGFloat(w), lines)
    }

    // MARK: - Lyrics

    struct Word {
        let text: String
        /// Normalised, origin top-left.
        let box: CGRect
        /// Printed with a dash after it — 「며—」: the syllable is held over
        /// the notes that follow.
        var held = false
    }

    /// The words under each staff, one per syllable (Korean) or word
    /// (Latin), each with its own box.
    ///
    /// READ THREE TIMES AND VOTED: once over the whole page, and each strip
    /// under a staff on its own at two sizes. Every single read got some
    /// syllables wrong and each got different ones — the page missed
    /// 「—신—」 standing alone, a strip read 「주의 주」 as 「주」, another
    /// 「알파」 as 「악파」. A syllable is kept when two reads see it there,
    /// and spelled the way most of them spell it.
    static func lyricWords(in image: CGImage, staves: [CGRect], chords: [CGRect] = []) -> [Word] {
        var reads: [[Word]] = [[], [], []]
        reads[0] = readWords(image).filter { word in
            staves.contains { word.box.midY > $0.maxY && word.box.midY < $0.maxY + $0.height * 4.5 }
        }
        for (index, staff) in staves.enumerated() {
            let gap = staff.height / 4
            let top = staff.maxY + gap * 0.3
            // Two crops of the strip under the staff. Generous: down to near
            // the next staff — Vision reads best with room around a line, but
            // where a lyric line and the next chord line share a height it
            // read them as one, 「합당한주」 over 「G D G」 as 「합금당한중레」.
            // Tight: down to just above the next staff's chords — clear of
            // them, but trimming the syllables they nearly touch. Each fails
            // where the other does not, which is what the vote is for.
            let generous = index + 1 < staves.count ? staves[index + 1].minY - gap * 1.5
                                                    : min(1, staff.maxY + staff.height * 4)
            var tight = generous
            if index + 1 < staves.count {
                let next = staves[index + 1]
                let tops = chords.filter { $0.midY > staff.maxY && $0.midY < next.minY }.map(\.minY).sorted()
                if !tops.isEmpty { tight = min(tight, tops[tops.count / 2] - gap * 0.1) }
            }
            // Pass 1, the strip whole; pass 2, each line of it on its own.
            // A clean block of four verses under a hymn's second staff came
            // back from the whole strip as 「1111」; cut at the blank rows
            // between lines, every line read.
            guard generous > top + gap else { continue }
            let strip = CGRect(x: 0, y: top, width: 1, height: generous - top)
            let pixels = CGRect(x: 0, y: strip.minY * CGFloat(image.height), width: CGFloat(image.width),
                                height: strip.height * CGFloat(image.height)).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            if let large = ScoreRecognition.enlarged(crop, by: 2) {
                reads[1] += readWords(large).map { word in
                    Word(text: word.text,
                         box: CGRect(x: word.box.minX, y: strip.minY + word.box.minY * strip.height,
                                     width: word.box.width, height: word.box.height * strip.height))
                }
            }
            let tightRows = Int((tight - top) * CGFloat(image.height))
            for line in textLines(in: crop) where line.lowerBound < max(tightRows, 1) {
                let pad = max(2, line.count / 4)
                let y0 = max(0, line.lowerBound - pad), y1 = min(crop.height, line.upperBound + pad)
                guard y1 - y0 > 4,
                      let piece = crop.cropping(to: CGRect(x: 0, y: y0, width: crop.width, height: y1 - y0)),
                      let large = ScoreRecognition.enlarged(piece, by: 2) else { continue }
                let lineTop = strip.minY + CGFloat(y0) / CGFloat(image.height)
                let lineHeight = CGFloat(y1 - y0) / CGFloat(image.height)
                reads[2] += readWords(large).map { word in
                    Word(text: word.text,
                         box: CGRect(x: word.box.minX, y: lineTop + word.box.minY * lineHeight,
                                     width: word.box.width, height: word.box.height * lineHeight))
                }
            }
        }
        // Nothing printed on a staff, and no chord symbol, is a lyric.
        reads = reads.map { read in
            read.filter { word in
                !isChordSymbol(word.text)
                    && !staves.contains { word.box.midY > $0.minY - $0.height * 0.125 && word.box.midY < $0.maxY + $0.height * 0.075 }
            }
        }
        // The line-by-line read is trusted on its own for a Korean syllable
        // nothing else contradicts. On a 1600 px hymn, the page read and
        // the strip read both missed every syllable printed under a chord
        // letter — the first of each bar — so only this read had them, and
        // the vote dropped 「의」지하는, 「내」 주를, 「더」욱 in all four
        // verses.
        let words = voted(reads, trusted: 2)
        // On a Korean chart a Latin word under the staff is a chord read
        // badly — 「DSUS4」, 「D9E」 — or an instruction, not a lyric.
        let hangul = words.filter { isKorean($0.text) }.count
        if Double(hangul) >= Double(words.count) * 0.7 {
            return words.filter { isKorean($0.text) }
        }
        return words
    }

    static func isKorean(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// One word per place where at least two reads put one, spelled as
    /// most of them spell it — the first read that has it breaking a tie.
    /// A Korean syllable only `trusted` saw is kept too.
    static func voted(_ reads: [[Word]], trusted: Int? = nil) -> [Word] {
        struct Slot { var box: CGRect; var texts: [Int: String]; var held = false }
        var slots: [Slot] = []
        for (pass, read) in reads.enumerated() {
            for word in read {
                let match = slots.firstIndex { slot in
                    guard slot.texts[pass] == nil else { return false }
                    let overlap = min(slot.box.maxX, word.box.maxX) - max(slot.box.minX, word.box.minX)
                    return overlap > min(slot.box.width, word.box.width) * 0.4
                        && abs(slot.box.midY - word.box.midY) < max(slot.box.height, word.box.height) * 0.6
                }
                if let match {
                    slots[match].texts[pass] = word.text
                    slots[match].held = slots[match].held || word.held
                } else {
                    slots.append(Slot(box: word.box, texts: [pass: word.text], held: word.held))
                }
            }
        }
        let agreed = slots.filter { $0.texts.count >= 2 }
        return slots.compactMap { slot in
            if slot.texts.count == 1, let trusted, let text = slot.texts[trusted], isKorean(text) {
                // Not where a syllable the reads agreed on already stands:
                // the same syllable boxed a little to one side is a
                // duplicate, 「주만만」.
                let taken = agreed.contains { other in
                    let overlap = min(other.box.maxX, slot.box.maxX) - max(other.box.minX, slot.box.minX)
                    return overlap > min(other.box.width, slot.box.width) * 0.25
                        && abs(other.box.midY - slot.box.midY) < max(other.box.height, slot.box.height) * 0.6
                }
                return taken ? nil : Word(text: text, box: slot.box, held: slot.held)
            }
            guard slot.texts.count >= 2 else { return nil }
            var counts: [String: Int] = [:]
            for text in slot.texts.values { counts[text, default: 0] += 1 }
            let best = counts.values.max() ?? 0
            let text = slot.texts.keys.sorted().compactMap { slot.texts[$0] }.first { counts[$0] == best } ?? ""
            return Word(text: text, box: slot.box, held: slot.held)
        }
    }

    /// Rows of an image holding a line of text: runs of inked rows between
    /// blank ones, at least a few pixels tall.
    static func textLines(in image: CGImage) -> [Range<Int>] {
        guard let gray = ScoreRecognition.grayscale(image) else { return [] }
        let w = image.width, h = image.height
        var inked = [Bool](repeating: false, count: h)
        for y in 0..<h {
            var count = 0
            for x in 0..<w where gray[y * w + x] < 160 { count += 1; if count > 2 { break } }
            inked[y] = count > 2
        }
        var lines: [Range<Int>] = []
        var start: Int?
        var blank = 0
        for y in 0...h {
            if y < h, inked[y] {
                if start == nil { start = y }
                blank = 0
            } else if let s = start {
                blank += 1
                // A row or two of white inside a line is the gap in 「ㅡ」.
                if blank > 2 || y == h {
                    let end = y - blank + 1
                    if end - s >= 6 { lines.append(s..<end) }
                    start = nil; blank = 0
                }
            }
        }
        return lines
    }

    /// Whether a word is a chord symbol rather than a lyric.
    static func isChordSymbol(_ text: String) -> Bool {
        guard !isKorean(text) else { return false }
        let repaired = ScoreRecognition.repairedChordWord(text)
        if ScoreChordText.parse(repaired) != nil { return true }
        // Read in capitals: 「DSUS4」.
        guard let first = repaired.first else { return false }
        return ScoreChordText.parse(String(first) + repaired.dropFirst().lowercased()) != nil
    }

    /// Lines of lyrics in an image, word by word.
    private static func readWords(_ image: CGImage) -> [Word] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        var words: [Word] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let lineStart = words.count
            let text = candidate.string
            guard isLyricLine(text) else { continue }

            var index = text.startIndex
            while index < text.endIndex {
                guard !text[index].isWhitespace else { index = text.index(after: index); continue }
                var end = index
                while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                let range = index..<end
                let token = text[range]
                // Korean is boxed syllable by syllable: Vision often runs
                // spaced syllables together, and 「거룩하」 as one box put
                // 「하」 in the bar before its own.
                if token.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                    var c = range.lowerBound
                    while c < range.upperBound {
                        let next = text.index(after: c)
                        if text[c].unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }),
                           let box = try? candidate.boundingBox(for: c..<next)?.boundingBox {
                            // A dash straight after it, in the same token: held.
                            let held = next < range.upperBound && Self.dashes.contains(text[next])
                            words.append(Word(text: String(text[c..<next]), box: flipped(box), held: held))
                        } else if Self.dashes.contains(text[c]), let last = words.indices.last,
                                  last >= lineStart, Self.isKorean(words[last].text) {
                            // A dash before a syllable — 「하 —며」 — holds the
                            // one before it, on the same line.
                            words[last].held = true
                        }
                        c = next
                    }
                } else if token.allSatisfy({ Self.dashes.contains($0) }) {
                    // 「하 - 시네」: a dash on its own holds the syllable
                    // before it. As a word of its own it found no slot in
                    // the vote and the hold was lost.
                    if let last = words.indices.last, last >= lineStart, Self.isKorean(words[last].text) {
                        words[last].held = true
                    }
                } else if let box = try? candidate.boundingBox(for: range)?.boundingBox {
                    words.append(Word(text: String(token), box: flipped(box)))
                }
                index = end
            }
        }
        return words
    }

    /// The marks a held syllable is printed with.
    static let dashes: Set<Character> = ["—", "–", "-", "_", "~", "ー", "ㅡ"]

    /// A line of lyrics rather than an instruction, a credit or noise.
    static func isLyricLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        let notLyrics = ["go to", "d.s", "d.c", "coda", "fine", "ending", "intro", "outro", "ccli",
                         "copyright", "©", "www.", "http", "repeat", "interlude", "간주", "반복"]
        if notLyrics.contains(where: { lower.contains($0) }) { return false }
        let letters = text.filter(\.isLetter)
        // Korean lyrics — a syllable standing alone, 「앞」, is a lyric — or
        // words of Latin letters; not a run of symbols.
        let hangul = letters.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        if hangul > 0 { return true }
        return letters.count >= 2 && Double(letters.count) / Double(max(text.count, 1)) > 0.5
    }

    /// Words grouped into lines, top to bottom — one per verse.
    static func verseLines(_ words: [Word]) -> [[Word]] {
        var lines: [[Word]] = []
        for word in words.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = lines.last, let anchor = last.first,
               abs(word.box.midY - anchor.box.midY) < max(anchor.box.height, word.box.height) * 0.6 {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// Syllables as one run of words: extender dashes gone, a verse number
    /// at the start gone, Korean syllables joined, English words spaced —
    /// and an English syllable ending in a hyphen joined to the next.
    static func joined(_ words: [Word]) -> String {
        var out = ""
        var glue = true
        for (i, word) in words.enumerated() {
            var text = word.text
            if i == 0, let number = text.range(of: #"^\d+\."#, options: .regularExpression) {
                text.removeSubrange(number)
            }
            let hyphenated = text.hasSuffix("-")
            text = text.filter { !"—–-_~".contains($0) }
            guard !text.isEmpty else { continue }
            let korean = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
            if !out.isEmpty, !glue, !korean { out += " " }
            out += text
            glue = korean || hyphenated
        }
        return out
    }

    private static func flipped(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
