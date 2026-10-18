//
//  check-chord-parts.swift
//  SolaPraise
//
//  Checks the stand's 코드 추가 wheels against the reader that saves them.
//
//  WHY THIS EXISTS: a quality on the wheel that ScoreChordText does not
//  know would be offered, picked, and then refused on 저장 with 「코드로
//  읽을 수 없습니다」 — the wheel and the reader disagreeing, silently, until
//  somebody picks that one. And typed text that turns the wheels to the
//  wrong chord would save something other than what was typed.
//
//  Run:
//      swiftc -O -o /tmp/chordparts \
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ChordParts.swift \
//          Tools/check-chord-parts.swift
//      /tmp/chordparts
//

import Foundation

@main
struct CheckChordParts {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }

        // Every chord the wheels can make is one the stand reads.
        for root in ChordParts.roots {
            for quality in ChordParts.qualities {
                for bass in [""] + ChordParts.roots {
                    let parts = ChordParts(root: root, quality: quality, bass: bass)
                    expect(ScoreChordText.parse(parts.text) != nil, "the reader refuses 「\(parts.text)」")
                    // And typed back, it turns the wheels to the same place.
                    expect(ChordParts(parts.text) == parts, "「\(parts.text)」 does not read back as itself")
                }
            }
        }

        // Typed the way people type.
        let typed: [(String, ChordParts?)] = [
            ("G", ChordParts(root: "G")),
            ("Em7", ChordParts(root: "E", quality: "m7")),
            ("D/F#", ChordParts(root: "D", bass: "F#")),
            ("C#m", ChordParts(root: "C#", quality: "m")),
            ("Bbsus4", ChordParts(root: "Bb", quality: "sus4")),
            ("F♯m7♭5", ChordParts(root: "F#", quality: "m7b5")),
            (" A7sus4 ", ChordParts(root: "A", quality: "7sus4")),
            ("Gmaj7/B", ChordParts(root: "G", quality: "maj7", bass: "B")),
            // Halfway through typing: the wheels wait.
            ("", nil),
            ("Em", ChordParts(root: "E", quality: "m")),
            ("Emaj", nil),
            ("D/", nil),
            // Not chords.
            ("H", nil),
            ("사랑", nil),
        ]
        for (text, want) in typed {
            expect(ChordParts(text) == want, "「\(text)」 reads as \(String(describing: ChordParts(text)))")
        }

        expect(ChordParts.display("F#") == "F♯" && ChordParts.display("Bb") == "B♭"
               && ChordParts.display("E") == "E", "wheel spelling")

        if failures == 0 {
            print("all chord parts checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
