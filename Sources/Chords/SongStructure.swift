//
//  SongStructure.swift
//  SolaPraise
//
//  Derives 곡의 진행 — verse / chorus / bridge — from a detected chord
//  timeline, by finding the chord blocks that repeat.
//
//  This needs no licence and no external data: the structure is inferred from
//  the harmony the app heard itself. Lyrics are a separate, manual layer,
//  because Korean worship lyrics are copyrighted and have no legitimate API.
//

import Foundation

// MARK: - Section

struct SongSection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Pattern letter — sections sharing a letter share a chord progression.
    var patternKey: String
    /// User-facing name: 절 1, 후렴, 브릿지 …
    var label: String
    /// Index range into the session's chord array.
    var startIndex: Int
    var endIndex: Int          // inclusive
    var startTime: TimeInterval
    /// Typed by the user. Never fetched — see the note above.
    var lyrics: String = ""

    var chordCount: Int { endIndex - startIndex + 1 }
}

// MARK: - Detection

enum SongStructure {

    /// Common section names, offered when renaming.
    static let suggestedLabels = ["절 1", "절 2", "후렴", "브릿지", "간주", "인트로", "아웃트로"]

    /// Splits a chord timeline into sections.
    ///
    /// Finds the repeating unit length that explains the most of the sequence,
    /// chunks on it, then merges neighbouring chunks that share a progression.
    /// The most-repeated progression is guessed to be 후렴, since in worship
    /// the chorus is what comes back most often; everything is renameable
    /// because that guess is only a heuristic.
    static func detect(chords: [SessionChord]) -> [SongSection] {
        guard chords.count >= 4 else {
            guard !chords.isEmpty else { return [] }
            return [SongSection(
                patternKey: "A", label: "전체",
                startIndex: 0, endIndex: chords.count - 1,
                startTime: chords[0].timestamp
            )]
        }

        let symbols = chords.map { $0.asChord.symbol() }
        let unit = bestRepeatingUnit(symbols)

        // Chunk on the unit length and key each chunk by its progression.
        var chunks: [(key: String, start: Int, end: Int)] = []
        var index = 0
        while index < symbols.count {
            let end = min(index + unit - 1, symbols.count - 1)
            let key = symbols[index...end].joined(separator: "-")
            chunks.append((key, index, end))
            index = end + 1
        }

        // Distinct progressions get letters in order of first appearance.
        var letterFor: [String: String] = [:]
        var counts: [String: Int] = [:]
        var nextLetter = UnicodeScalar("A").value
        for chunk in chunks {
            if letterFor[chunk.key] == nil {
                letterFor[chunk.key] = String(UnicodeScalar(nextLetter) ?? "A")
                nextLetter += 1
            }
            counts[chunk.key, default: 0] += 1
        }

        let chorusKey = counts.filter { $0.value > 1 }.max { $0.value < $1.value }?.key
        let firstKey = chunks.first?.key

        // Merge neighbouring chunks that share a progression.
        var sections: [SongSection] = []
        var verseNumber = 0
        for chunk in chunks {
            let letter = letterFor[chunk.key] ?? "A"
            if var last = sections.last, last.patternKey == letter {
                last.endIndex = chunk.end
                sections[sections.count - 1] = last
                continue
            }

            let label: String
            if chunk.key == chorusKey {
                label = "후렴"
            } else if chunk.key == firstKey {
                verseNumber += 1
                label = "절 \(verseNumber)"
            } else {
                label = "섹션 \(letter)"
            }

            sections.append(SongSection(
                patternKey: letter,
                label: label,
                startIndex: chunk.start,
                endIndex: chunk.end,
                startTime: chords[chunk.start].timestamp
            ))
        }
        return sections
    }

    /// Picks the phrase length to chunk on.
    ///
    /// Scores each candidate by how many chords are explained by a progression
    /// that occurs more than once. Ties are common and matter: in a typical
    /// verse-chorus song, units of 2, 4 and 8 all score identically, because a
    /// repeating 8-chord block also repeats at 4 and at 2. Taking the shortest
    /// chops the song into meaningless two-chord fragments, and the longest
    /// swallows verse and chorus into one block. So among the tied winners,
    /// prefer the shortest multiple of four — the phrase length worship and pop
    /// writing overwhelmingly use.
    private static func bestRepeatingUnit(_ symbols: [String]) -> Int {
        let maxUnit = min(16, max(2, symbols.count / 2))
        var scores: [Int: Int] = [:]

        for unit in 2...maxUnit {
            var seen: [String: Int] = [:]
            var index = 0
            while index + unit <= symbols.count {
                let key = symbols[index..<(index + unit)].joined(separator: "-")
                seen[key, default: 0] += 1
                index += unit
            }
            scores[unit] = seen.filter { $0.value > 1 }.reduce(0) { $0 + $1.value * unit }
        }

        guard let best = scores.values.max(), best > 0 else {
            // Nothing repeated — through-composed, or detection that never
            // settled. Fall back to the four-chord phrase rather than to 2.
            return 4
        }

        let winners = scores.filter { $0.value == best }.keys.sorted()
        return winners.first { $0 % 4 == 0 } ?? winners.first ?? 4
    }
}
