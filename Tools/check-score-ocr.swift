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
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ScoreRecognition.swift \
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
        let width = 1190, height = 1684
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
