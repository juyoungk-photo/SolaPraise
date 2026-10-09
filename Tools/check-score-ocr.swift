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

    static func main() {
        // A4 at 2× — the size the app rasterises a PDF page to.
        let width = 1190, height = 1684
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { print("no context"); exit(1) }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = graphics
        // Flip so y grows downward, like a page.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let chordFont = NSFont.boldSystemFont(ofSize: 30)
        let lyricFont = NSFont.systemFont(ofSize: 34)

        // Chords spaced as a real chart spaces them: over the syllable they
        // fall on, not evenly. Includes a slash chord, a flat, a seventh,
        // a sus, and a sharp — the forms whose characters OCR mangles.
        let rows: [(chords: [(String, CGFloat)], lyric: String)] = [
            ([("G", 120), ("D/F#", 420), ("Em", 700), ("C", 960)],
             "주 하나님 지으신 모든 세계 내 마음 속에"),
            ([("Am7", 120), ("D", 480), ("Gsus4", 720), ("G", 1000)],
             "그리어 볼 때 하늘의 별 울려 퍼지는"),
            ([("Bb", 140), ("F", 440), ("Cm", 720), ("Eb", 980)],
             "주님의 권능 우주에 찼네"),
            ([("C", 120), ("G/B", 400), ("Am", 680), ("D7", 960)],
             "내 영혼아 찬양하라"),
            // Lone capitals only — the line Vision is worst at, with no
            // longer symbol on it to anchor a second look.
            ([("C", 130), ("E", 470), ("A", 800), ("D", 1020)],
             "주님께 영광 돌리세"),
        ]

        var placed: [Placed] = []
        var y: CGFloat = 160
        // Rows 190pt apart, five rows: the page is A4 at 2×, so this fits.
        for row in rows {
            for (chord, x) in row.chords {
                (chord as NSString).draw(at: CGPoint(x: x, y: y),
                                         withAttributes: [.font: chordFont,
                                                          .foregroundColor: NSColor.black])
                placed.append(Placed(text: chord, x: x, lineY: y))
            }
            (row.lyric as NSString).draw(at: CGPoint(x: 110, y: y + 46),
                                         withAttributes: [.font: lyricFont,
                                                          .foregroundColor: NSColor.black])
            y += 190
        }
        // A title and a credit line: Latin text that is NOT a chord.
        ("Amazing Grace - Arr. by Example" as NSString)
            .draw(at: CGPoint(x: 110, y: 60),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 36),
                                   .foregroundColor: NSColor.black])

        guard let image = context.makeImage() else { print("no image"); exit(1) }

        let found = ScoreRecognition.chords(in: image)
        print("found:", found.map(\.original))

        // Every drawn chord found, by its normalised spelling.
        let wanted = placed.map(\.text)
        let got = found.map { $0.original.replacingOccurrences(of: "♯", with: "#") }
        let missing = wanted.filter { want in !got.contains(want) }
        check("every chord on the page is found", missing.isEmpty, "missing \(missing)")

        // Nothing invented from the title or the lyrics.
        let extra = got.filter { !wanted.contains($0) }
        check("no word of the title is taken for a chord", extra.isEmpty, "extra \(extra)")

        // Each found chord sits where it was drawn. Within a third of a
        // chord-width horizontally is enough to paint over the right one.
        var misplaced: [String] = []
        for item in found {
            let x = item.box.minX * CGFloat(width)
            let top = item.box.minY * CGFloat(height)
            let near = placed.contains { p in
                p.text == item.original && abs(p.x - x) < 30 && abs(p.lineY - top) < 30
            }
            if !near { misplaced.append("\(item.original)@\(Int(x)),\(Int(top))") }
        }
        check("every chord's box is where it was drawn", misplaced.isEmpty,
              "misplaced \(misplaced)")

        // The key: these chords are mostly G-family on rows 1, 2 and 4.
        check("score in G, team plays in A → +2",
              ScoreRecognition.shift(fromScoreChords: ["G", "D", "Em", "C", "G", "D", "G"],
                                     toKey: "A") == 2)
        check("score in G, team plays in F → −2, not +10",
              ScoreRecognition.shift(fromScoreChords: ["G", "C", "G", "D"], toKey: "F") == -2)
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
