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
        guard let suffix = knownSuffix(remainder) else { return nil }

        return Parsed(root: root, suffix: suffix, bass: bass, usesFlats: usesFlats)
    }

    /// The suffix as this vocabulary spells it, accepting how charts print
    /// it: raised in parentheses — 「G(sus4)」, 「G(SUS4)」 — or in capitals.
    /// A 「G(sus4)」 read as nothing left a G on a transposed page, in the
    /// old key, on every chart typeset that way.
    private static func knownSuffix(_ text: String) -> String? {
        var candidates = [text]
        if text.hasPrefix("("), text.hasSuffix(")"), text.count > 2 {
            candidates.append(String(text.dropFirst().dropLast()))
        }
        for candidate in candidates {
            if suffixes.contains(candidate) { return candidate }
            // Capitals only for words: 「M7」 is major and 「m7」 minor, so a
            // two-letter suffix keeps its case.
            if candidate.count >= 3, suffixes.contains(candidate.lowercased()) { return candidate.lowercased() }
        }
        return nil
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

    /// The MAJOR key a chart is probably in, as a root (0 = C), in the
    /// order its chords appear.
    ///
    /// Not the most common root, which was the first rule and was wrong on
    /// a real chart: a song in G with one more D chord than G chords came
    /// out "in D", and the whole page was transposed six steps instead of
    /// one. A key is the set of chords that belong to it, so each of the
    /// twelve keys is scored by how well the chords fit — the I, IV and V
    /// count most, ii, iii and vi a little less, a chord outside the key
    /// counts against it — and songs tend to open and close on the tonic.
    /// A minor song comes out as its relative major, which shares its
    /// chords; ScoreRecognition.shift compares like with like.
    static func likelyRoot(of symbols: [String]) -> Int? {
        let chords = symbols.compactMap(parse)
        guard !chords.isEmpty else { return nil }

        func isMinor(_ c: Parsed) -> Bool {
            c.suffix.hasPrefix("m") && !c.suffix.hasPrefix("maj")
        }
        var best: (key: Int, score: Double)?
        for key in 0..<12 {
            var score = 0.0
            for chord in chords {
                switch ((chord.root - key) % 12 + 12) % 12 {
                case 0, 5, 7: score += isMinor(chord) ? 0.3 : 2      // I, IV, V
                case 2, 4, 9: score += isMinor(chord) ? 1.5 : 0.5    // ii, iii, vi
                case 10:      score += 0.2                           // ♭VII, common in worship
                default:      score -= 1
                }
            }
            if let first = chords.first, first.root == key, !isMinor(first) { score += 2 }
            if let last = chords.last, last.root == key, !isMinor(last) { score += 3 }
            // The relative minor's tonic at the edges points here too.
            if let last = chords.last, last.root == (key + 9) % 12, isMinor(last) { score += 2 }
            if best == nil || score > best!.score { best = (key, score) }
        }
        return best?.key
    }

    /// A key written in a chart's file name or title — 「Album Title
    /// (G).pdf」, 「주님 뜻대로 [Bb]」, 「Key of E」, 「Key: F#m」, 「A키」.
    ///
    /// WHY: guessing the key from the chords is right most of the time and
    /// wrong when recognition missed some, or when a song lives on its IV.
    /// Publishers and teams usually name the file by its key, and what the
    /// file says is what was printed — so a key in the name wins, and the
    /// chord estimate is only a fallback and a cross-check.
    ///
    /// Only a key standing alone counts: 「(G)」 but not 「(Gospel)」, 「Key of
    /// E」 but not 「Edition」. Returns the relative MAJOR root (0 = C), to
    /// compare with likelyRoot, and the key as written.
    static func keyHint(in name: String) -> (root: Int, written: String)? {
        var text = name.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        if let dot = text.range(of: #"\.(pdf|png|jpe?g|heic)$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(dot)
        }
        let key = #"([A-G][#b]?)(m(?:in(?:or)?)?|\s?[Mm]ajor|\s?minor)?"#
        let patterns = [
            #"(?i:key)\s*(?:of|:|=|-)?\s*"# + key + #"(?![A-Za-z#])"#,   // Key of G, Key: F#m
            #"[(\[]\s*"# + key + #"\s*(?:(?i:key))?\s*[)\]]"#,         // (G) [Bb] (Em) (G key)
            #"(?<![A-Za-z])"# + key + #"\s?키"#,                             // G키, Bb 키
            #"(?<![A-Za-z])"# + key + #"\s*(?i:key)(?![A-Za-z])"#,          // G Key
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let noteRange = Range(match.range(at: 1), in: text),
                  let (note, _, rest) = readNote(String(text[noteRange])), rest.isEmpty else { continue }
            let quality = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            let minor = quality.lowercased().contains("m") && !quality.lowercased().contains("major")
            let written = String(text[noteRange]) + (minor ? "m" : "")
            return ((note + (minor ? 3 : 0)) % 12, written)
        }
        return nil
    }
}
