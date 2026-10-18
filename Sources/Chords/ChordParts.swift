//
//  ChordParts.swift
//  SolaPraise
//
//  A chord as the three things a player picks it by — root, quality, bass —
//  for the stand's 코드 추가 wheels.
//
//  WHY: typing 「F#m7」 on a phone means a keyboard switch for 「#」 and a
//  Korean keyboard turning 「B」 into 「ㅠ」. The wheels build the same text
//  the field takes, and the field, typed into, turns the wheels to match.
//  Every quality offered is one ScoreChordText reads, so nothing the wheels
//  make is refused on 저장 (Tools/check-chord-parts.swift).
//

import Foundation

struct ChordParts: Equatable {
    var root: String
    var quality: String
    /// Empty when there is no slash bass.
    var bass: String

    /// What is written: 「F#m7/C#」.
    var text: String { root + quality + (bass.isEmpty ? "" : "/" + bass) }

    /// Both spellings of each black key: a chart in E♭ writes B♭, not A♯.
    static let roots = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb",
                        "G", "G#", "Ab", "A", "A#", "Bb", "B"]

    /// The ones worship charts use, most used first.
    static let qualities = ["", "m", "7", "m7", "maj7", "sus4", "sus2", "7sus4",
                            "add9", "9", "m9", "maj9", "6", "m6", "11", "m11", "13",
                            "dim", "dim7", "aug", "m7b5", "5"]

    /// The chord a wheel shows when nothing is typed yet: the key's chord.
    init(root: String = "C", quality: String = "", bass: String = "") {
        self.root = root
        self.quality = quality
        self.bass = bass
    }

    /// The wheels' reading of typed text, or nil while it is not (yet) a
    /// chord the wheels hold — then they stay where they are.
    init?(_ typed: String) {
        let text = typed.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        let halves = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = halves.first, let root = Self.leadingRoot(head) else { return nil }
        let quality = String(head.dropFirst(root.count))
        guard Self.qualities.contains(quality) else { return nil }
        var bass = ""
        if halves.count == 2 {
            guard Self.roots.contains(halves[1]) else { return nil }
            bass = halves[1]
        }
        self.init(root: root, quality: quality, bass: bass)
    }

    /// 「C#m」 is C♯ minor, not C with a quality 「#m」.
    private static func leadingRoot(_ text: String) -> String? {
        if text.count >= 2, roots.contains(String(text.prefix(2))) { return String(text.prefix(2)) }
        if let first = text.first, roots.contains(String(first)) { return String(first) }
        return nil
    }

    /// As shown on a wheel: ♯ and ♭ rather than # and b.
    static func display(_ note: String) -> String {
        guard note.count == 2 else { return note }
        return String(note.prefix(1)) + (note.hasSuffix("b") ? "♭" : "♯")
    }
}
