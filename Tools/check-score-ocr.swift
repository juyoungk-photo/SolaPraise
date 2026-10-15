//
//  check-score-ocr.swift
//  SolaPraise
//
//  Draws a score page — chord lines over Korean lyric lines — then runs the
//  app's own recogniser on it and checks what comes back.
//
//  WHY THIS EXISTS: a recogniser that misses chords fails silently. The
//  page comes out "transposed" with half its chords still in the old key,
//  which is worse than not transposing at all, and nothing anywhere
//  reports an error. Each drawn chord is also checked for WHERE it was
//  found, because the transposed symbol is painted over that box: a box
//  one chord to the left covers the wrong symbol and leaves the real one
//  showing.
//
//  Run:
//      swiftc -O -o /tmp/scoreocr \
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ScoreRecognition.swift Sources/Chords/ScoreChart.swift \
//          Tools/check-score-ocr.swift
//      /tmp/scoreocr
//

import Foundation
import AppKit
import CoreGraphics

@main
struct CheckScoreOCR {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    /// A chord as drawn: its text and the x it starts at, in points.
    struct Placed { let text: String; let x: CGFloat; let lineY: CGFloat }

    typealias Row = (chords: [(String, CGFloat)], lyric: String)

    /// Draws a page — chord lines over lyric lines — and returns the image
    /// and where each chord went.
    static func render(rows: [Row], chordSize: CGFloat, lyricSize: CGFloat,
                       spacing: CGFloat) -> (CGImage, [Placed])? {
        // A4 at 2× — the size the app rasterises a PDF page to.
        let width = Self.width, height = 1684
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Flip so y grows downward, like a page.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let chordFont = NSFont.boldSystemFont(ofSize: chordSize)
        let lyricFont = NSFont.systemFont(ofSize: lyricSize)
        var placed: [Placed] = []
        var y: CGFloat = 160
        for row in rows {
            for (chord, x) in row.chords {
                (chord as NSString).draw(at: CGPoint(x: x, y: y),
                                         withAttributes: [.font: chordFont, .foregroundColor: NSColor.black])
                placed.append(Placed(text: chord, x: x, lineY: y))
            }
            (row.lyric as NSString).draw(at: CGPoint(x: 110, y: y + chordSize * 1.5),
                                         withAttributes: [.font: lyricFont, .foregroundColor: NSColor.black])
            y += spacing
        }
        // A title and a credit line: Latin text that is NOT a chord.
        ("Amazing Grace - Arr. by Example" as NSString)
            .draw(at: CGPoint(x: 110, y: 60),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        return context.makeImage().map { ($0, placed) }
    }

    /// Runs the recogniser on a page and checks what came back.
    static func audit(_ name: String, rows: [Row], chordSize: CGFloat, lyricSize: CGFloat,
                      spacing: CGFloat, tolerance: CGFloat) {
        guard let (image, placed) = render(rows: rows, chordSize: chordSize,
                                           lyricSize: lyricSize, spacing: spacing) else {
            check("\(name): page renders", false); return
        }
        let found = ScoreRecognition.chords(in: image)
        print("\(name) found \(found.count)/\(placed.count):", found.map(\.original))

        // Every drawn chord, counted — a page with two G's needs two found.
        var remaining = found
        var missing: [String] = []
        var misplaced: [String] = []
        for p in placed {
            if let index = remaining.firstIndex(where: { item in
                item.original.replacingOccurrences(of: "♯", with: "#") == p.text
                    && abs(item.box.minX * CGFloat(image.width) - p.x) < tolerance
                    && abs(item.box.minY * CGFloat(image.height) - p.lineY) < tolerance
            }) {
                remaining.remove(at: index)
            } else if found.contains(where: { $0.original == p.text }) {
                misplaced.append("\(p.text)@\(Int(p.x))")
            } else {
                missing.append("\(p.text)@\(Int(p.x))")
            }
        }
        check("\(name): every chord on the page is found", missing.isEmpty, "missing \(missing)")
        check("\(name): every chord's box is where it was drawn", misplaced.isEmpty,
              "misplaced \(misplaced)")
        let wanted = Set(placed.map(\.text))
        let extra = remaining.map(\.original).filter { !wanted.contains($0) }
        check("\(name): no word of the title or lyrics is taken for a chord", extra.isEmpty,
              "extra \(extra)")
    }

    /// A LEAD SHEET IN STAFF NOTATION, the shape of a real chart the app
    /// read badly (16 of 46 chords): each chord in a thin serif font above a
    /// five-line staff, note stems reaching up toward it, a boxed rehearsal
    /// mark, voltas 「1.G」 「2.G」, a 「Go to A」 instruction, slash chords,
    /// and a key-signature sharp on each staff.
    static let width = 1190

    static func staffPage() {
        let width = 1190, height = 1684
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let serif = NSFont(name: "Times New Roman", size: 26) ?? NSFont.systemFont(ofSize: 26)
        let text: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: NSColor.black]
        let lyric: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]
        let systems: [(chords: [(String, CGFloat)], lyrics: String)] = [
            ([("G", 160), ("C9", 420), ("Am", 680), ("Dsus4", 930)], "거룩 하신 전능 의 주 찬양 받기 합당한 주"),
            ([("D", 150), ("G", 300), ("C9", 480), ("Am", 660), ("G", 860), ("D", 930), ("G", 1000)], "나의 평생 주님 만을 사랑 하며 따르리라"),
            ([("C9", 160), ("Dsus4", 400), ("1.G", 620), ("2.G", 760), ("D/E", 900), ("D9/F#", 1000)], "찬양 하며 경배 해 귀하 신 만 왕의 왕"),
        ]
        // Each system's first chord sits clear of the staff's start, as on
        // a real chart, where clef and key signature come first: a mark at
        // the very start is a measure number, and is dropped.
        var placed: [Placed] = []
        var y: CGFloat = 200
        for (index, system) in systems.enumerated() {
            let staffTop = y + 60
            context.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
            context.setLineWidth(1.4)
            for line in 0..<5 {
                let ly = staffTop + CGFloat(line) * 16
                context.move(to: CGPoint(x: 90, y: ly)); context.addLine(to: CGPoint(x: 1110, y: ly))
            }
            context.strokePath()
            // The key signature: a ♯ on the top line, which the phone's
            // recogniser read as 「F」.
            // Drawn as engraved: two uprights about two and a half spaces
            // tall around the line, two thick slanted bars, clear of the
            // chord line above it.
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2)
            for x in [CGFloat(102), 110] {
                context.move(to: CGPoint(x: x, y: staffTop - 9)); context.addLine(to: CGPoint(x: x, y: staffTop + 26))
            }
            context.strokePath()
            context.setLineWidth(5)
            for y in [staffTop - 1, staffTop + 12] {
                context.move(to: CGPoint(x: 97, y: y + 3)); context.addLine(to: CGPoint(x: 115, y: y - 3))
            }
            context.strokePath()
            // Note heads and stems, some reaching up into the chord strip.
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2.5)
            for x in stride(from: CGFloat(200), to: 1080, by: 70) {
                let head = staffTop + 40
                context.fillEllipse(in: CGRect(x: x, y: head, width: 14, height: 10))
                context.move(to: CGPoint(x: x + 13, y: head + 4)); context.addLine(to: CGPoint(x: x + 13, y: staffTop - 14))
            }
            context.strokePath()
            for (chord, x) in system.chords {
                (chord as NSString).draw(at: CGPoint(x: x, y: y + 22), withAttributes: text)
                let name = chord.hasPrefix("1.") || chord.hasPrefix("2.") ? String(chord.dropFirst(2)) : chord
                placed.append(Placed(text: name, x: x, lineY: y + 22))
            }
            // A measure number at the staff's start, over where the clef
            // goes — italic, small; one read as 「A」 on a real chart.
            if index > 0 {
                let italic = NSFontManager.shared.convert(NSFont(name: "Times New Roman", size: 18) ?? serif,
                                                          toHaveTrait: .italicFontMask)
                ("\(index * 8 + 1)" as NSString).draw(at: CGPoint(x: 92, y: staffTop - 24),
                                                     withAttributes: [.font: italic, .foregroundColor: NSColor.black])
            }
            // The volta bracket over 1.G and 2.G.
            if index == 2 {
                context.setLineWidth(1.5)
                context.move(to: CGPoint(x: 605, y: y + 14)); context.addLine(to: CGPoint(x: 880, y: y + 14))
                context.strokePath()
            }
            (system.lyrics as NSString).draw(at: CGPoint(x: 110, y: staffTop + 90), withAttributes: lyric)
            y += 400
        }
        // A boxed rehearsal mark and a 「Go to A」 instruction: neither is a chord.
        ("A" as NSString).draw(at: CGPoint(x: 100, y: 160), withAttributes: text)
        context.setLineWidth(2)
        context.stroke(CGRect(x: 94, y: 156, width: 32, height: 36))
        ("Go to A" as NSString).draw(at: CGPoint(x: 560, y: 1490), withAttributes: text)

        guard let image = context.makeImage() else { check("staff page renders", false); return }

        // The phone's recogniser read the ♯ as a chord with its box cut at
        // the top line; the Mac's does not, so the ink test is checked on
        // its own: through every staff's top line in the key signature's
        // columns, and not under a chord.
        let staves = ScoreRecognition.staves(in: image)
        check("staff page: three staves found", staves.count == 3, "found \(staves.count)")
        func through(_ x: CGFloat, _ width: CGFloat) -> Int {
            staves.filter { staff in
                ScoreRecognition.runsIntoStaff(
                    CGRect(x: x / CGFloat(self.width), y: staff.staff.minY - staff.staff.height * 0.3,
                           width: width / CGFloat(self.width), height: staff.staff.height * 0.25),
                    staff: staff.staff, in: image)
            }.count
        }
        check("a key-signature ♯ runs into every staff", through(96, 20) == staves.count,
              "\(through(96, 20)) of \(staves.count)")
        check("a chord above the staff does not", through(158, 22) == 0, "\(through(158, 22))")
        let found = ScoreRecognition.chords(in: image)
        print("staff page found \(found.count)/\(placed.count):", found.map(\.original))
        var remaining = found
        var missing: [String] = []
        for p in placed {
            if let i = remaining.firstIndex(where: { $0.original == p.text
                && abs($0.box.minX * CGFloat(width) - p.x) < 30 }) {
                remaining.remove(at: i)
            } else { missing.append("\(p.text)@\(Int(p.x))") }
        }
        check("staff page: every chord above a staff is found", missing.isEmpty, "missing \(missing)")
        check("staff page: no rehearsal mark, instruction or note taken for a chord",
              remaining.isEmpty, "extra \(remaining.map { "\($0.original)@\(Int($0.box.minX * CGFloat(width)))" })")
    }

    /// A HYMNAL PAGE: sans-serif chords crowded down onto the staff, four
    /// sharps, a 6/8 time signature, measure numbers, verse lines, and
    /// chords written with a real ♯ — 「G♯」 「C♯m」 「F♯」. Note stems rise
    /// into the chord line; one in the opening of the C read 「C♯m」 as
    /// 「G#m」. Beamed stems as tall as the staff, which are not barlines,
    /// and an end repeat, which is. Drawn at the size of a phone screenshot.
    static func hymnPage() {
        let width = 800, height = 870
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ font: String = "Helvetica") {
            let f = NSFont(name: font, size: size) ?? NSFont.systemFont(ofSize: size)
            (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: f, .foregroundColor: NSColor.black])
        }
        text("주님 앞에 나아갑니다", 260, 8, 32)
        text("(찬송가 000장)", 330, 58, 18)
        text("KaMU", 10, 80, 18)
        text("E. P. Writer / I. D. Composer", 570, 78, 15)
        let verse = "1.주 님 앞에 나 아가 오늘 도 함께 하 - 시네"
        let systems: [(staff: CGFloat, chords: [(String, CGFloat)], number: String?, verses: Int)] = [
            (148, [("E", 120), ("B7", 310), ("E", 385), ("A", 462), ("E", 638), ("B7", 728)], nil, 4),
            (400, [("E", 105), ("A", 292), ("E", 450), ("B7", 652), ("E", 728)], "5", 4),
            (650, [("E", 110), ("B", 292), ("G♯", 455), ("C♯m", 540), ("F♯", 643), ("B7", 728)], "9", 1),
            (790, [("E", 110), ("B", 190), ("E7", 285), ("A", 370), ("E", 446), ("B7", 658), ("E", 728)], "13", 1),
        ]
        var placed: [Placed] = []
        for system in systems {
            let top = system.staff
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1)
            for line in 0..<5 {
                let y = top + CGFloat(line) * 9
                context.move(to: CGPoint(x: 8, y: y)); context.addLine(to: CGPoint(x: 792, y: y))
            }
            context.strokePath()
            // Four sharps — F C G D — as engraved.
            for (i, dy) in [0, 13.5, -4.5, 9].enumerated() {
                let x = 40 + CGFloat(i) * 9, c = top + CGFloat(dy)
                context.setLineWidth(1.2)
                for upright in [x + 2, x + 5] {
                    context.move(to: CGPoint(x: upright, y: c - 9)); context.addLine(to: CGPoint(x: upright, y: c + 9))
                }
                context.strokePath()
                context.setLineWidth(2.5)
                for bar in [c - 3, c + 3] {
                    context.move(to: CGPoint(x: x, y: bar + 1.5)); context.addLine(to: CGPoint(x: x + 7, y: bar - 1.5))
                }
                context.strokePath()
            }
            if let number = system.number { text(number, 4, top - 22, 11, "Times New Roman") }
            else { text("6", 88, top - 3, 20, "Times New Roman"); text("8", 88, top + 15, 20, "Times New Roman") }
            // Notes, stems up, reaching above the top line.
            context.setLineWidth(1.2)
            for x in stride(from: CGFloat(125), to: 780, by: 42) {
                let head = top + CGFloat([9, 13.5, 18, 22.5][Int(x) % 4])
                context.fillEllipse(in: CGRect(x: x, y: head - 3.5, width: 10, height: 7))
                context.move(to: CGPoint(x: x + 9.5, y: head)); context.addLine(to: CGPoint(x: x + 9.5, y: head - 27))
                context.strokePath()
            }
            for x in [CGFloat(290), 445, 625, 790] {
                context.move(to: CGPoint(x: x, y: top)); context.addLine(to: CGPoint(x: x, y: top + 36))
            }
            context.strokePath()
            // Two eighths beamed on the top line, heads in the bottom space:
            // stems exactly as tall as the staff, which are not barlines.
            context.fillEllipse(in: CGRect(x: 322, y: top + 28, width: 10, height: 7))
            context.fillEllipse(in: CGRect(x: 352, y: top + 28, width: 10, height: 7))
            context.move(to: CGPoint(x: 331.5, y: top + 31)); context.addLine(to: CGPoint(x: 331.5, y: top))
            context.move(to: CGPoint(x: 361.5, y: top + 31)); context.addLine(to: CGPoint(x: 361.5, y: top))
            context.strokePath()
            context.fill(CGRect(x: 331, y: top - 1, width: 31, height: 4))
            // The second row ends on a repeat: dots, thin, thick.
            if system.number == "5" {
                context.fillEllipse(in: CGRect(x: 774, y: top + 11.5, width: 4.5, height: 4.5))
                context.fillEllipse(in: CGRect(x: 774, y: top + 20.5, width: 4.5, height: 4.5))
                context.fill(CGRect(x: 786, y: top, width: 5, height: 36))
            }
            for (chord, x) in system.chords {
                text(chord, x, top - 33, 18)
                placed.append(Placed(text: chord.replacingOccurrences(of: "♯", with: "#"), x: x, lineY: top - 33))
            }
            for v in 0..<system.verses {
                text(verse.replacingOccurrences(of: "1.", with: "\(v + 1)."), 100, top + 50 + CGFloat(v) * 32, 26)
            }
        }

        guard let image = context.makeImage() else { check("hymn page renders", false); return }
        let found = ScoreRecognition.chords(in: image)
        print("hymn page found \(found.count)/\(placed.count):", found.map(\.original))
        var remaining = found
        var missing: [String] = []
        for p in placed {
            if let i = remaining.firstIndex(where: { $0.original == p.text
                && abs($0.box.minX * CGFloat(width) - p.x) < 20 }) {
                remaining.remove(at: i)
            } else { missing.append("\(p.text)@\(Int(p.x))") }
        }
        check("hymn page: every chord found, C♯m not read as G#m", missing.isEmpty, "missing \(missing)")
        check("hymn page: no title, credit, measure number or sharp taken for a chord",
              remaining.isEmpty, "extra \(remaining.map { "\($0.original)@\(Int($0.box.minX * CGFloat(width)))" })")
        check("hymn page: in E", ScoreChordText.likelyRoot(of: found.map(\.original)) == 4)

        // 코드표: the same page read as bars, chords and verses.
        let names = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.original) })
        let chart = ScoreChart.read(image, chords: found.map { ScoreChart.ChordMark(id: $0.id, box: $0.box) })
        let barChords = chart.map { system in
            system.bars.map { bar in bar.segments.compactMap { $0.chord.flatMap { names[$0] } } }
        }
        check("chart: four rows of four bars", chart.map(\.bars.count) == [4, 4, 4, 4],
              "got \(chart.map(\.bars.count))")
        check("chart: each chord in the bar it starts in",
              barChords.first == [["E"], ["B7", "E"], ["A"], ["E", "B7"]]
                  && barChords.last == [["E", "B"], ["E7", "A"], ["E"], ["B7", "E"]],
              "got \(barChords)")
        check("chart: the second row ends on a repeat, and no other bar does",
              chart.map { $0.bars.map(\.repeatEnd) } == [[false, false, false, false], [false, false, false, true],
                                                         [false, false, false, false], [false, false, false, false]],
              "got \(chart.map { $0.bars.map(\.repeatEnd) })")
        check("chart: four verses under the first two rows, one under the rest",
              chart.map(\.verses) == [4, 4, 1, 1], "got \(chart.map(\.verses))")
        let verseText = { (system: ScoreChart.System, line: Int) in
            system.bars.flatMap(\.segments).map { line < $0.lyrics.count ? $0.lyrics[line] : "" }.joined()
        }
        if let first = chart.first {
            check("chart: a verse reads whole, its number and dashes gone",
                  verseText(first, 0) == "주님앞에나아가오늘도함께하시네", "got 「\(verseText(first, 0))」")
            // 코드표 lays a staff out as syllables in columns: a verse must
            // read whole across them, and every chord sit on a column.
            let cellsLine = first.bars.flatMap(\.cells)
            let sung = cellsLine.map { $0.syllables.first ?? "" }.joined()
            check("chart: syllable columns read the verse whole", sung == "주님앞에나아가오늘도함께하시네", "got 「\(sung)」")
            check("chart: every chord of the line sits on a column",
                  cellsLine.compactMap(\.chord).count == first.bars.flatMap(\.segments).compactMap(\.chord).count)
            // 「하 - 시네」: the dash holds 하 over the next note. The 코드표
            // draws it as 「하—」; nothing else on the line is held.
            let held = cellsLine.filter { $0.isHeld(0) }.map { $0.syllables.first ?? "" }
            check("chart: the syllable before a dash is held, and only it", held == ["하"], "got \(held)")
            check("chart: the fourth verse is its own line",
                  first.verses == 4 && verseText(first, 3) == "주님앞에나아가오늘도함께하시네", "got 「\(verseText(first, 3))」")
        }
    }

    static func main() {
        // Chords spaced as a real chart spaces them: over the syllable they
        // fall on, not evenly. Includes a slash chord, a flat, a seventh,
        // a sus, and a sharp — the forms whose characters OCR mangles.
        audit("standard page", rows: [
            ([("G", 120), ("D/F#", 420), ("Em", 700), ("C", 960)], "주 하나님 지으신 모든 세계 내 마음 속에"),
            ([("Am7", 120), ("D", 480), ("Gsus4", 720), ("G", 1000)], "그리어 볼 때 하늘의 별 울려 퍼지는"),
            ([("Bb", 140), ("F", 440), ("Cm", 720), ("Eb", 980)], "주님의 권능 우주에 찼네"),
            ([("C", 120), ("G/B", 400), ("Am", 680), ("D7", 960)], "내 영혼아 찬양하라"),
            // Lone capitals only — the line Vision is worst at, with no
            // longer symbol on it to anchor a second look.
            ([("C", 130), ("E", 470), ("A", 800), ("D", 1020)], "주님께 영광 돌리세"),
        ], chordSize: 30, lyricSize: 34, spacing: 190, tolerance: 30)

        // A DENSE CHART, the kind a team actually prints: small chords,
        // several to a bar, close enough that two can read as one word.
        // This is the page the user reported chords missing from.
        audit("dense page", rows: [
            ([("G", 110), ("D/F#", 170), ("Em7", 260), ("C", 340), ("Dsus4", 420), ("D", 520),
              ("G", 640), ("C/E", 700), ("D", 790), ("G", 860)], "주 하나님 지으신 모든 세계 내 마음 속에 그리어 볼 때"),
            ([("Am7", 110), ("D7", 190), ("Bm", 260), ("Em", 330), ("Am", 420), ("D", 500),
              ("G", 600), ("E", 660), ("A", 720), ("D", 780)], "하늘의 별 울려 퍼지는 뇌성 주님의 권능 우주에 찼네"),
            ([("F", 110), ("C", 170), ("Bb", 230), ("F/A", 300), ("Gm7", 390), ("C7", 470),
              ("F", 560), ("Dm", 620), ("Bb", 690), ("C", 760)], "내 영혼아 찬양하라 주님의 높고 위대하심을"),
        ], chordSize: 20, lyricSize: 22, spacing: 120, tolerance: 22)

        // The key: these chords are mostly G-family on rows 1, 2 and 4.
        staffPage()
        hymnPage()

        check("a ♯ read as t, ‡ or ＃ is a sharp",
              ScoreRecognition.repairedChordWord("Gt") == "G#" && ScoreRecognition.repairedChordWord("C‡m") == "C#m"
                && ScoreRecognition.repairedChordWord("F＃7") == "F#7")
        check("a word that merely starts with a letter is left alone",
              ScoreRecognition.repairedChordWord("Go") == "Go" && ScoreRecognition.repairedChordWord("Ate") == "Ate")
        check("score in G, team plays in A → +2",
              ScoreRecognition.shift(fromScoreChords: ["G", "D", "Em", "C", "G", "D", "G"],
                                     toKey: "A") == 2)
        check("score in G, team plays in F → −2, not +10",
              ScoreRecognition.shift(fromScoreChords: ["G", "C", "G", "D"], toKey: "F") == -2)
        check("a minor team key compares with the relative major: G chart, team in Em → 0",
              ScoreRecognition.shift(fromScoreChords: ["G", "C", "D", "Em", "G"], toKey: "Em") == 0)
        check("G chart, team in F#m → +2 (A major)",
              ScoreRecognition.shift(fromScoreChords: ["G", "C", "D", "Em", "G"], toKey: "F#m") == 2)
        check("no team key → no default shift",
              ScoreRecognition.shift(fromScoreChords: ["G"], toKey: nil) == nil)
        check("key spellings: Bb, F#m, E major, D키",
              ScoreRecognition.keyRoot("Bb") == 10 && ScoreRecognition.keyRoot("F#m") == 6
              && ScoreRecognition.keyRoot("E major") == 4 && ScoreRecognition.keyRoot("D키") == 2)
        check("a key that is not a key is rejected",
              ScoreRecognition.keyRoot("미정") == nil && ScoreRecognition.keyRoot("Gsus4") == nil)

        print(failures == 0 ? "\nall score OCR checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
