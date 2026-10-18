//
//  check-chord-glyphs.swift
//  SolaPraise
//
//  Draws chord symbols the way charts set them — a ♯ or ♭ glyph, a small
//  raised digit, a bracket round an optional chord — in several faces,
//  and checks that ChordGlyphs tells the parts apart and reads the chord.
//
//  WHY THIS EXISTS: the text engine does not know a music ♯ or a raised
//  7, and a chart's 「F♯m」 came back 「Fm」 — a chord in the wrong quality
//  with nothing anywhere saying so. The shape rules that name those
//  glyphs are checked here on glyphs drawn in the faces printed charts
//  use, so a rule tuned on one chart's face is caught on another's.
//
//  Run:
//      swiftc -O -o /tmp/chordglyphs \
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ScoreRecognition.swift \
//          Sources/Chords/ChordGlyphs.swift Tools/check-chord-glyphs.swift
//      /tmp/chordglyphs
//

import Foundation
import AppKit

@main
struct CheckChordGlyphs {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
        }
        if !ok { failures += 1 }
    }

    /// A strip like the one above a staff: the chords on one row, the
    /// accidental a music glyph in a text face, the digit raised and small.
    static func strip(_ chords: [(String, CGFloat)], face: String, size: CGFloat, unit: CGFloat) -> CGImage? {
        let width = 2200, height = Int(unit * 5)
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        let font = NSFont(name: face, size: size) ?? NSFont.systemFont(ofSize: size)
        let small = NSFont(name: face, size: size * 0.6) ?? NSFont.systemFont(ofSize: size * 0.6)
        let baseline = CGFloat(height) * 0.35
        for (chord, x) in chords {
            var cursor = x
            var index = chord.startIndex
            while index < chord.endIndex {
                let ch = chord[index]
                let text: String, used: NSFont, rise: CGFloat
                if ch == "^" {
                    // 「^7」: the next character raised.
                    index = chord.index(after: index)
                    text = String(chord[index]); used = small; rise = size * 0.45
                } else {
                    text = String(ch); used = font; rise = 0
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: used, .foregroundColor: NSColor.black]
                (text as NSString).draw(at: CGPoint(x: cursor, y: baseline + rise), withAttributes: attrs)
                cursor += (text as NSString).size(withAttributes: attrs).width
                index = chord.index(after: index)
            }
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func main() {
        // What the charts print, and what should be read. 「^」 raises the
        // next character; ♯ and ♭ are the music glyphs.
        let cases: [(printed: String, want: String)] = [
            ("F♯m", "F#m"), ("E/G♯", "E/G#"), ("C♯^7", "C#7"), ("B♭", "Bb"), ("E♭maj^7", "Ebmaj7"),
            ("C^9", "C9"), ("Em^7", "Em7"), ("Dsus^4", "Dsus4"), ("A^2", "A2"), ("B^7/D♯", "B7/D#"),
            ("(E^7)", "E7"), ("G", "G"), ("D/F♯", "D/F#"), ("Bm", "Bm"), ("A#m7", "A#m7"),
        ]
        let faces = ["Helvetica", "Helvetica-Bold", "TimesNewRomanPSMT", "ArialMT", "Georgia"]
        for face in faces {
            for unit in [CGFloat(10), 16] {
                let size = unit * 1.9
                // Each chord its own width and three units apart, as a chart sets them.
                let font = NSFont(name: face, size: size) ?? NSFont.systemFont(ofSize: size)
                var placed: [(String, CGFloat)] = []
                var x: CGFloat = 40
                for c in cases {
                    placed.append((c.printed, x))
                    let drawn = c.printed.replacingOccurrences(of: "^", with: "")
                    x += (drawn as NSString).size(withAttributes: [.font: font]).width + unit * 3
                }
                guard let image = strip(placed, face: face, size: size, unit: unit),
                      let gray = ChordGlyphs.grayscale(image) else { check("\(face) draws", false); continue }
                // Drawn at the screen's scale: the image may be twice the size.
                let scale = CGFloat(image.width) / 2200
                let read = ChordGlyphs.read(strip: image, unit: unit * scale, threshold: ChordGlyphs.threshold(gray))
                var wrong: [String] = []
                for (c, at) in zip(cases, placed) {
                    let hit = read.first { abs($0.box.minX - at.1 * scale) < 30 * scale }
                    let got = hit?.text ?? "nothing"
                    if got.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b") != c.want {
                        wrong.append("\(c.printed)→\(got)")
                    }
                }
                check("\(face) at unit \(Int(unit)): every chord read as printed",
                      wrong.isEmpty, wrong.joined(separator: "  "))
            }
        }
        if failures == 0 { print("\nall chord glyph checks passed") } else { print("\n\(failures) failure(s)"); exit(1) }
    }
}
