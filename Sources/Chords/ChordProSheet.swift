//
//  ChordProSheet.swift
//  SolaPraise
//
//  A chart's 코드표 as ChordPro sees a song: sections — 1절, 2절, 후렴 —
//  of lines, each line words, each chord set before the syllable it is
//  played on. What the 코드표 shows, and what goes out as a .chordpro file.
//
//  WHY CHORDPRO: it is how chord charts are written down everywhere else —
//  a plain text format that chord apps on any phone open, transpose and
//  print — and its way of laying a song out is the one musicians read
//  fastest: each verse whole, its chords over its own words, the chorus
//  once and named after. The 코드표 used to set every verse under one chord
//  line, note by note with dashes, as a hymnal does; a band reading it
//  mid-song had to find their verse's row in each line.
//
//  FROM THE READING: each staff's cells — a chord, a syllable per verse —
//  give each verse a line. Syllables become words as Korean is written
//  (LyricSpacing). A staff with more than one verse under it is a verse
//  line; a staff with only one, among staves with several, is the refrain
//  sung after each — written once as 후렴 and named after the other
//  verses. A staff with chords and no words is an instrumental line.
//
//  Foundation only: Tools/check-chordpro.swift runs it.
//

import Foundation

enum ChordProSheet {

    /// A chord and the lyrics it is played over, up to the next chord.
    struct Piece: Equatable {
        var chord: String?
        var text: String
    }

    /// One word as sung — the unit a line wraps at — with any chords that
    /// change inside it.
    struct Word: Equatable {
        var pieces: [Piece]
    }

    struct Line: Equatable {
        var words: [Word]
        /// The staff it was read from, for 가사 고치기.
        var system: Int
        var repeatStart = false
        var repeatEnd = false
        /// Chords only: an intro, an interlude.
        var isInstrumental: Bool { words.allSatisfy { $0.pieces.allSatisfy { $0.text.isEmpty } } }
    }

    struct Section: Equatable {
        enum Kind: Equatable { case verse, chorus, chorusAgain, plain }
        var kind: Kind
        var label: String?
        var lines: [Line]
    }

    struct Song: Equatable {
        var title: String?
        var key: String?
        var sections: [Section]
    }

    // MARK: - From the reading

    static func song(systems: [ScoreChart.System], chord: (UUID) -> String?,
                     title: String? = nil, key: String? = nil) -> Song {
        let lyricVerses = systems.map { verseCount($0) }
        let verses = lyricVerses.max() ?? 0
        // One verse throughout: the song as it goes, no labels.
        guard verses > 1 else {
            let lines = systems.indices.compactMap { line(systems[$0], index: $0, verse: 0, chord: chord) }
            return Song(title: title, key: key, sections: lines.isEmpty ? [] : [Section(kind: .plain, lines: lines)])
        }
        let refrain = systems.indices.filter { lyricVerses[$0] == 1 }
        let verseLines = systems.indices.filter { lyricVerses[$0] > 1 || lyricVerses[$0] == 0 }
        let chorusFirst = (refrain.first ?? .max) < (systems.indices.first { lyricVerses[$0] > 1 } ?? .max)
        let chorus = refrain.compactMap { line(systems[$0], index: $0, verse: 0, chord: chord) }

        var sections: [Section] = []
        if chorusFirst, !chorus.isEmpty { sections.append(Section(kind: .chorus, label: "후렴", lines: chorus)) }
        for verse in 0..<verses {
            // Instrumental staves go with the first verse, where they stand.
            let lines = verseLines.compactMap { index -> Line? in
                if lyricVerses[index] == 0 { return verse == 0 ? line(systems[index], index: index, verse: 0, chord: chord) : nil }
                return line(systems[index], index: index, verse: verse, chord: chord)
            }
            guard !lines.isEmpty else { continue }
            sections.append(Section(kind: .verse, label: "\(verse + 1)절", lines: lines))
            if !chorus.isEmpty, !chorusFirst {
                sections.append(sections.contains { $0.kind == .chorus }
                                ? Section(kind: .chorusAgain, label: "후렴", lines: [])
                                : Section(kind: .chorus, label: "후렴", lines: chorus))
            } else if !chorus.isEmpty, chorusFirst {
                sections.append(Section(kind: .chorusAgain, label: "후렴", lines: []))
            }
        }
        return Song(title: title, key: key, sections: sections)
    }

    /// How many verse lines of words a staff has — 0 for chords only.
    private static func verseCount(_ system: ScoreChart.System) -> Int {
        let cells = system.bars.flatMap(\.cells)
        let verses = cells.map(\.syllables.count).max() ?? 0
        return (0..<verses).filter { verse in
            cells.contains { verse < $0.syllables.count && !$0.syllables[verse].trimmingCharacters(in: .whitespaces).isEmpty }
        }.count
    }

    /// One verse's words on one staff, chords before the syllables they
    /// are played on; nil when it has neither.
    static func line(_ system: ScoreChart.System, index: Int, verse: Int, chord: (UUID) -> String?) -> Line? {
        struct Slot { var chord: String?; var syllable: String; var startsWord = false }
        var slots: [Slot] = []
        for bar in system.bars {
            for cell in bar.cells {
                let name = cell.chord.flatMap(chord)
                let syllable = verse < cell.syllables.count ? cell.syllables[verse].trimmingCharacters(in: .whitespaces) : ""
                if name == nil && syllable.isEmpty { continue }
                slots.append(Slot(chord: name, syllable: syllable))
            }
        }
        guard !slots.isEmpty else { return nil }
        // Spaced as written, and corrected (LyricSpacing).
        let sung = slots.indices.filter { !slots[$0].syllable.isEmpty }
        let spaced = LyricSpacing.space(sung.map { slots[$0].syllable })
        for (k, index) in sung.enumerated() {
            slots[index].syllable = spaced.syllables[k]
            slots[index].startsWord = spaced.startsWord[k]
        }
        var words: [Word] = []
        for slot in slots {
            // A chord over no syllable — a held note, a bar's rest — is a
            // word of its own; a syllable that starts a word starts one.
            let startsNew = words.isEmpty || slot.syllable.isEmpty || slot.startsWord
                || (words.last?.pieces.last.map { $0.text.isEmpty } ?? true)
            if startsNew {
                words.append(Word(pieces: [Piece(chord: slot.chord, text: slot.syllable)]))
            } else if let chord = slot.chord {
                words[words.count - 1].pieces.append(Piece(chord: chord, text: slot.syllable))
            } else {
                let last = words[words.count - 1].pieces.count - 1
                words[words.count - 1].pieces[last].text += slot.syllable
            }
        }
        return Line(words: words, system: index,
                    repeatStart: system.bars.first?.repeatStart ?? false,
                    repeatEnd: system.bars.last?.repeatEnd ?? false)
    }

    // MARK: - As a .chordpro file

    static func text(_ song: Song) -> String {
        var out: [String] = []
        if let title = song.title { out.append("{title: \(title)}") }
        if let key = song.key { out.append("{key: \(key)}") }
        for section in song.sections {
            if !out.isEmpty { out.append("") }
            switch section.kind {
            case .verse: out.append("{start_of_verse: \(section.label ?? "")}")
            case .chorus: out.append("{start_of_chorus: \(section.label ?? "")}")
            case .chorusAgain:
                out.append("{chorus: \(section.label ?? "")}")
                continue
            case .plain: break
            }
            for line in section.lines { out.append(text(line)) }
            switch section.kind {
            case .verse: out.append("{end_of_verse}")
            case .chorus: out.append("{end_of_chorus}")
            default: break
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func text(_ line: Line) -> String {
        let words = line.words.map { word in
            word.pieces.map { piece in (piece.chord.map { "[\($0)]" } ?? "") + piece.text }.joined()
        }
        var text = words.joined(separator: " ")
        if line.repeatStart { text = "𝄆 " + text }
        if line.repeatEnd { text += " 𝄇" }
        return text
    }
}
