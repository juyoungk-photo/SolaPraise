//
//  ScoreChordText.swift
//  SolaPraise
//
//  Deciding whether a piece of text on a score is a chord symbol, and
//  transposing it if it is.
//
//  This is the part that has to be right. Everything else in the feature —
//  reading text off an image, drawing the new symbol back — is mechanical,
//  but a symbol wrongly RECOGNISED puts a chord on a chart that nobody
//  played, and a symbol wrongly REJECTED leaves the old key sitting in the
//  middle of a transposed page. The second is worse: a chart in two keys at
//  once is unplayable in a way an obviously missing chord is not.
//
//  So it is deliberately conservative, and it is pure string handling with
//  no Vision, no UIKit and no file access, so it can be exercised directly.
//  See Tools/check-score-chords.swift.
//
//  WHAT MAKES THIS TRACTABLE AT ALL: Korean worship scores have Korean
//  lyrics. A run of Latin letters on the page is therefore almost always a
//  chord rather than a word, which is a far better starting position than
//  an English chart would give. An English score will produce false
//  positives on "A", "Am", "Be", "Dad" — and that is called out to the user
//  rather than hidden, because the app cannot tell the difference.
//

import Foundation

enum ScoreChordText {

    /// A chord symbol found in a piece of recognised text.
    struct Parsed: Equatable {
        let root: Int           // 0 = C
        let suffix: String      // "m7", "sus4", "" …
        let bass: Int?          // slash chord
        /// Whether the original was written with flats, so the transposed
        /// one can be written the same way.
        let usesFlats: Bool
    }

    private static let sharpNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    private static let flatNames  = ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"]

    /// Suffixes a chord symbol may carry. Longest first, so "maj7" is tried
    /// before "m" would ever match the "m" inside it.
    private static let suffixes: [String] = [
        "maj7", "maj9", "maj13", "maj", "M7", "M9",
        "m7b5", "m7", "m9", "m11", "m13", "m6", "min", "m",
        "sus2", "sus4", "sus",
        "add9", "add2", "add11",
        "dim7", "dim", "aug",
        "7sus4", "7sus", "13", "11", "9", "7", "6", "5",
        "°", "ø", "+", ""
    ]

    // MARK: - Parsing

    /// Reads a chord symbol, or returns nil when the text is not one.
    ///
    /// The whole token must be a chord. A partial match is how "Faith"
    /// becomes F and "Amen" becomes Am, which would scatter invented chords
    /// across a page of English lyrics.
    static func parse(_ raw: String) -> Parsed? {
        let text = normalise(raw)
        guard !text.isEmpty, text.count <= 10 else { return nil }

        guard let (root, usesFlats, afterRoot) = readNote(text) else { return nil }

        var remainder = afterRoot
        var bass: Int?
        if let slash = remainder.firstIndex(of: "/") {
            let bassText = String(remainder[remainder.index(after: slash)...])
            guard let (bassNote, _, rest) = readNote(bassText), rest.isEmpty else { return nil }
            bass = bassNote
            remainder = String(remainder[..<slash])
        }

        // Whatever is left has to be a suffix this vocabulary knows. An
        // unknown tail means the token was a word that merely began like a
        // chord, which is exactly the case to reject.
        guard suffixes.contains(where: { $0 == remainder }) else { return nil }

        return Parsed(root: root, suffix: remainder, bass: bass, usesFlats: usesFlats)
    }

    /// Note letter plus optional accidental, and what follows it.
    private static func readNote(_ text: String) -> (note: Int, flats: Bool, rest: String)? {
        guard let first = text.first,
              let base = "CDEFGAB".firstIndex(of: first) else { return nil }
        let semitonesFromC = [0, 2, 4, 5, 7, 9, 11]
        var value = semitonesFromC["CDEFGAB".distance(from: "CDEFGAB".startIndex, to: base)]

        var rest = String(text.dropFirst())
        var flats = false
        if let accidental = rest.first {
            if accidental == "#" { value += 1; rest = String(rest.dropFirst()) }
            else if accidental == "b" {
                // "b" is also the start of no suffix at all, but a lone "b"
                // after a note letter is always an accidental in practice —
                // there is no chord quality that begins with it.
                value -= 1; flats = true; rest = String(rest.dropFirst())
            }
        }
        return ((value + 12) % 12, flats, rest)
    }

    /// Unicode accidentals and the stray spaces OCR leaves behind.
    private static func normalise(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "∕", with: "/")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Transposing

    /// The transposed symbol, written the way the original was.
    ///
    /// Accidental style is preserved rather than chosen: a chart written in
    /// flats stays in flats. Picking "correctly" per key would mean deciding
    /// that a team's own chart is written wrong, and the point here is to
    /// hand back the same page a step higher.
    static func transpose(_ parsed: Parsed, by semitones: Int) -> String {
        let names = parsed.usesFlats ? flatNames : sharpNames
        let root = names[((parsed.root + semitones) % 12 + 12) % 12]
        guard let bass = parsed.bass else { return root + parsed.suffix }
        let bassName = names[((bass + semitones) % 12 + 12) % 12]
        return root + parsed.suffix + "/" + bassName
    }

    /// Convenience: text in, transposed text out, nil when it is not a chord.
    static func transpose(text: String, by semitones: Int) -> String? {
        guard let parsed = parse(text) else { return nil }
        return transpose(parsed, by: semitones)
    }

    /// The key a page is probably in: the most common root among its chords,
    /// which is a decent proxy and the only one available from symbols alone.
    static func likelyRoot(of symbols: [String]) -> Int? {
        var counts: [Int: Int] = [:]
        for symbol in symbols {
            guard let parsed = parse(symbol) else { continue }
            counts[parsed.root, default: 0] += 1
        }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key
    }
}
