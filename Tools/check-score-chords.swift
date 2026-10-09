//
//  check-score-chords.swift
//  SolaPraise
//
//  Checks which text on a score is treated as a chord, and what it becomes
//  when transposed.
//
//  WHY THIS EXISTS: this decision is invisible and consequential. A symbol
//  wrongly RECOGNISED puts a chord on a chart nobody played. A symbol
//  wrongly REJECTED leaves the old key sitting in the middle of a
//  transposed page — a chart in two keys at once, which is unplayable in a
//  way a missing chord is not. Neither failure throws, logs, or looks wrong
//  until somebody is holding the page on a Sunday.
//
//  So the suite is mostly REJECTIONS. Accepting G and Bm7 is easy; the work
//  is in refusing "Face", "Dad", "Bead" and "Cab" while still accepting
//  "C#m7b5" and "G/B".
//
//  Run:
//      swiftc -O -o /tmp/scorecheck \
//          Sources/Chords/ScoreChordText.swift Tools/check-score-chords.swift
//      /tmp/scorecheck
//

import Foundation

@main
struct CheckScoreChords {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    /// Symbols a worship chart actually carries.
    static let chords = [
        "C", "G", "Am", "F", "D7", "Em7", "Bm", "A#", "Bb",
        "Csus4", "Dsus2", "Gadd9", "Fmaj7", "Bm7b5", "C#m7",
        "G/B", "D/F#", "Ab/C", "Edim", "Caug", "F6", "A7sus4"
    ]

    /// Text that appears on a page and must NOT be transposed.
    ///
    /// The English words are the dangerous ones: every letter A–G is also a
    /// word or the start of one, and a chart with English lyrics will put
    /// them directly under the chord line.
    static let notChords = [
        "Face", "Dad", "Bead", "Cab", "Age", "Bag", "Deed", "Edge",
        "Amen", "Faith", "Grace", "Be", "Can", "Bad", "Dear",
        "Verse", "Chorus", "Bridge", "Intro", "1절", "후렴",
        "주님", "은혜", "Capo", "Key", "BPM", "4/4", "120", "x2"
    ]

    static func main() {
        for symbol in chords {
            check("accepts \(symbol)", ScoreChordText.parse(symbol) != nil, "rejected")
        }
        for word in notChords {
            let parsed = ScoreChordText.parse(word)
            check("rejects \(word)", parsed == nil,
                  "read as \(parsed.map { ScoreChordText.transpose($0, by: 0) } ?? "?")")
        }

        // Transposition itself.
        let moves: [(String, Int, String)] = [
            ("C", 2, "D"), ("G", 1, "G#"), ("Am", 3, "Cm"),
            ("Bb", 2, "C"),
            // Bb up one is B natural, NOT Cb. A flat chart stays in flats
            // where flats exist, but the seventh degree is a white note and
            // spelling it Cb would be wrong on the page.
            ("Bb", 1, "B"),
            ("F#m7", 1, "Gm7"), ("G/B", 5, "C/E"),
            ("D", -2, "C"), ("C", -1, "B"), ("C", 12, "C")
        ]
        for (from, by, want) in moves {
            let got = ScoreChordText.transpose(text: from, by: by)
            check("\(from) +\(by) → \(want)", got == want, "got \(got ?? "nil")")
        }

        // Accidental STYLE is preserved: a chart in flats stays in flats,
        // because picking "correctly" per key means telling a team their own
        // chart is written wrong.
        check("sharp chart stays sharp",
              ScoreChordText.transpose(text: "C#", by: 1) == "D", "")
        check("flat chart stays flat",
              ScoreChordText.transpose(text: "Eb", by: 2) == "F", "")
        check("a flat root keeps flats when it moves to a black note",
              ScoreChordText.transpose(text: "Eb", by: 1) == "E", "")
        check("a sharp root keeps sharps when it moves to a black note",
              ScoreChordText.transpose(text: "D", by: 1) == "D#", "")

        // Unicode accidentals, which is what a typeset score uses.
        check("♯ is read as #", ScoreChordText.parse("F♯m") != nil, "rejected")
        check("♭ is read as b", ScoreChordText.parse("B♭") != nil, "rejected")

        // The key guess.
        check("most common root wins",
              ScoreChordText.likelyRoot(of: ["G", "C", "G", "D", "G"]) == 7,
              "got \(ScoreChordText.likelyRoot(of: ["G", "C", "G", "D", "G"]) ?? -1)")
        check("no chords, no key", ScoreChordText.likelyRoot(of: ["Verse", "주님"]) == nil)

        print(failures == 0
              ? "\nall score chord checks passed"
              : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
