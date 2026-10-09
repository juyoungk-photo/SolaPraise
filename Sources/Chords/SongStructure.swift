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
//  ── WHY THE FIRST VERSION FOUND NO REPEATS AT ALL ──────────────
//
//  It compared chunks of chord SYMBOLS for exact string equality. Three
//  things make that fail on essentially every real recording:
//
//  1. There are seventeen chord qualities, and the detector picks the
//     best-scoring one every frame. One sustained G is heard as
//     G → Gmaj7 → G6 → Gadd9 → G as the vocal moves over it, and because
//     `history` appends on any change, that is five events for one chord.
//     The same bar played twice produces two different event sequences.
//  2. Chunking counts EVENTS, not musical time. One spurious event shifts
//     every chunk boundary after it, so even a perfectly repeated chorus
//     lands in a different place the second time round.
//  3. A 0.3-second flicker weighed exactly as much as a four-bar chord.
//
//  So every chunk was unique, every section got its own letter, and 곡의
//  흐름 showed six differently-coloured blocks for a song with two parts.
//
//  The fix is to compare what a musician would call the same thing:
//
//  - Events shorter than a noise floor are dropped. They are flicker.
//  - Chords are compared by FUNCTION — root plus major/minor/dim/aug — so
//    Gmaj7, G6, Gsus4 and G are one thing while the chart still prints
//    what was actually heard.
//  - Two blocks are the same section when they agree on most positions,
//    not all of them, because one wrong chord in four is detection being
//    normal rather than the band playing something else.
//
//  And when the result is still thin, `quality` says so plainly instead of
//  letting the map present guesses as structure.
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

// MARK: - How much to trust it

/// What the detection actually gave us, and whether a structure drawn from
/// it means anything.
///
/// Surfaced rather than kept internal: a map that shows six sections for a
/// two-part song is worse than no map, because it looks like an answer.
struct StructureQuality: Equatable {

    enum Finding: String, Equatable {
        case tooFewChords
        case tooShort
        case veryNoisy
        case noRepetition
        case lowConfidence

        var message: String {
            switch self {
            case .tooFewChords:
                return "코드가 너무 적게 잡혔습니다. 곡 전체를 들려주면 구조가 나옵니다."
            case .tooShort:
                return "분석된 길이가 짧습니다. 한 절만으로는 반복을 찾을 수 없습니다."
            case .veryNoisy:
                return "코드가 자주 흔들렸습니다. 반주가 또렷한 구간에서 다시 해 보세요."
            case .noRepetition:
                return "반복되는 구간을 찾지 못했습니다. 구간 구분은 참고용입니다."
            case .lowConfidence:
                return "인식 신뢰도가 낮습니다. 마이크가 스피커에서 멀거나 소리가 작을 수 있습니다."
            }
        }
    }

    /// Harmonic events left after flicker was dropped.
    var events = 0
    /// Events the detector reported before cleaning.
    var rawEvents = 0
    /// How many were dropped as too short to be real.
    var dropped = 0
    /// Seconds the analysed chords span.
    var seconds: TimeInterval = 0
    /// Share of the song that sits in a progression occurring more than
    /// once. This is the number that says whether a structure was found.
    var repeatedShare: Double = 0
    var findings: [Finding] = []

    /// Whether the section map is worth drawing as fact.
    var isTrustworthy: Bool {
        findings.isEmpty || (!findings.contains(.noRepetition)
                             && !findings.contains(.tooFewChords))
    }

    /// The share of reported events that were flicker — the single best
    /// indicator that the input was poor rather than the song unusual.
    var noiseShare: Double {
        rawEvents > 0 ? Double(dropped) / Double(rawEvents) : 0
    }
}

// MARK: - Detection

enum SongStructure {

    /// Common section names, offered when renaming.
    static let suggestedLabels = ["절 1", "절 2", "후렴", "브릿지", "간주", "인트로", "아웃트로"]

    /// Below this, a chord is the detector changing its mind rather than the
    /// band changing chord. Worship tempos put a bar somewhere around two
    /// seconds, so half a second is already generous.
    private static let absoluteNoiseFloor: TimeInterval = 0.45

    /// Two blocks are the same section at this much agreement. Three
    /// positions in four: one wrong chord per phrase is ordinary detection,
    /// two is a different phrase.
    private static let sameSectionThreshold = 0.75

    static func detect(chords: [SessionChord]) -> [SongSection] {
        analyse(chords: chords).sections
    }

    static func quality(chords: [SessionChord]) -> StructureQuality {
        analyse(chords: chords).quality
    }

    // MARK: - The whole pass

    static func analyse(chords: [SessionChord])
    -> (sections: [SongSection], quality: StructureQuality) {

        var quality = StructureQuality()
        quality.rawEvents = chords.count

        guard chords.count >= 2 else {
            quality.events = chords.count
            quality.findings = [.tooFewChords]
            guard let only = chords.first else { return ([], quality) }
            return ([SongSection(patternKey: "A", label: "전체",
                                 startIndex: 0, endIndex: chords.count - 1,
                                 startTime: only.timestamp)], quality)
        }

        let events = clean(chords)
        quality.events = events.count
        quality.dropped = chords.count - events.count
        quality.seconds = (chords.last!.timestamp - chords.first!.timestamp)

        if quality.seconds < 45 { quality.findings.append(.tooShort) }
        if quality.noiseShare > 0.5 { quality.findings.append(.veryNoisy) }

        guard events.count >= 4 else {
            quality.findings.append(.tooFewChords)
            return ([SongSection(patternKey: "A", label: "전체",
                                 startIndex: 0, endIndex: chords.count - 1,
                                 startTime: chords[0].timestamp)], quality)
        }

        let keys = events.map(\.function)
        let (unit, offset) = bestRepeatingUnit(keys)

        // Chunk the cleaned events on that unit, starting at the offset that
        // actually lines the phrases up.
        //
        // Starting at zero was fragile in a way that bites on real songs: a
        // verse ending on C into a chorus beginning on C is ONE sustained C,
        // so cleaning merges them and every phrase after that point is a
        // chord out of step. The chunk boundaries then fall mid-phrase and
        // nothing matches anything. Trying each offset costs a handful of
        // comparisons and recovers the alignment.
        var chunks: [[Event]] = []
        if offset > 0 { chunks.append(Array(events[0..<offset])) }
        var index = offset
        while index < events.count {
            let end = min(index + unit, events.count)
            chunks.append(Array(events[index..<end]))
            index = end
        }

        // Group chunks that agree on MOST positions, not all of them.
        var groups: [[Int]] = []            // function sequence per group
        var groupOf: [Int] = []             // group index per chunk
        for chunk in chunks {
            let sequence = chunk.map(\.function)
            if let hit = groups.firstIndex(where: {
                similarity($0, sequence) >= sameSectionThreshold
            }) {
                groupOf.append(hit)
            } else {
                groups.append(sequence)
                groupOf.append(groups.count - 1)
            }
        }

        var counts: [Int: Int] = [:]
        for group in groupOf { counts[group, default: 0] += 1 }

        let repeatedChunks = groupOf.filter { (counts[$0] ?? 0) > 1 }.count
        quality.repeatedShare = chunks.isEmpty
            ? 0 : Double(repeatedChunks) / Double(chunks.count)
        if quality.repeatedShare < 0.25 { quality.findings.append(.noRepetition) }

        let sections = build(chunks: chunks, groupOf: groupOf, counts: counts)
        return (sections, quality)
    }

    // MARK: - Cleaning

    /// One harmonic event: a stretch of time the band spent on one function.
    private struct Event {
        let function: Int
        let startIndex: Int        // into the ORIGINAL chord array
        var endIndex: Int
        let start: TimeInterval
        var duration: TimeInterval
    }

    /// Drops flicker and merges neighbours that mean the same chord.
    ///
    /// Two passes, in this order on purpose: merging first would let a long
    /// run of alternating G/Gmaj7 survive as one event per flicker, and
    /// dropping first would delete the short halves of that alternation and
    /// leave the rest to merge properly.
    private static func clean(_ chords: [SessionChord]) -> [Event] {
        guard !chords.isEmpty else { return [] }

        // Durations, with the last event given the median so it is not
        // treated as zero-length and thrown away.
        var spans: [TimeInterval] = []
        for index in chords.indices {
            let next = index + 1 < chords.count
                ? chords[index + 1].timestamp : nil
            spans.append(next.map { $0 - chords[index].timestamp } ?? 0)
        }
        let positive = spans.filter { $0 > 0 }.sorted()
        let median = positive.isEmpty ? 1 : positive[positive.count / 2]
        if spans.indices.last != nil { spans[spans.count - 1] = median }

        let floor = max(absoluteNoiseFloor, median * 0.33)

        var kept: [Event] = []
        for (index, chord) in chords.enumerated() {
            guard spans[index] >= floor else { continue }
            let function = functionKey(chord.asChord)
            // Merge into the previous event when it is the same function:
            // the flicker between them has just been removed, so what is
            // left is one chord that was interrupted.
            if var last = kept.last, last.function == function {
                last.endIndex = index
                last.duration += spans[index]
                kept[kept.count - 1] = last
                continue
            }
            kept.append(Event(function: function,
                              startIndex: index,
                              endIndex: index,
                              start: chord.timestamp,
                              duration: spans[index]))
        }
        return kept
    }

    /// Root plus the family a musician would name, so that Gmaj7, G6, Gsus4
    /// and G all compare equal while the chart still prints what was heard.
    ///
    /// Sevenths and ninths are colour, not function: a chorus played with
    /// maj7s the second time round is the same chorus. Diminished and
    /// augmented stay distinct, because those genuinely change where the
    /// music is going.
    private static func functionKey(_ chord: Chord) -> Int {
        let family: Int
        switch chord.quality {
        case .minor, .minor7, .minor9, .minor6:        family = 1
        case .diminished:                              family = 2
        case .augmented:                               family = 3
        default:                                       family = 0
        }
        return chord.root * 4 + family
    }

    /// Share of positions two progressions agree on.
    private static func similarity(_ a: [Int], _ b: [Int]) -> Double {
        let span = max(a.count, b.count)
        guard span > 0 else { return 0 }
        // A short tail chunk should not count as a match for a full phrase
        // just because its few chords line up.
        guard min(a.count, b.count) * 2 >= span else { return 0 }
        let agree = zip(a, b).filter { $0 == $1 }.count
        return Double(agree) / Double(span)
    }

    // MARK: - Naming

    private static func build(chunks: [[Event]],
                              groupOf: [Int],
                              counts: [Int: Int]) -> [SongSection] {
        var letterFor: [Int: String] = [:]
        var order: [Int: Int] = [:]
        var nextLetter = UnicodeScalar("A").value
        for (position, group) in groupOf.enumerated() where letterFor[group] == nil {
            letterFor[group] = String(UnicodeScalar(nextLetter) ?? "A")
            order[group] = position
            nextLetter += 1
        }

        let firstGroup = groupOf.first

        // Which repeated progression is the 후렴.
        //
        // Taking `max` over a dictionary was not deterministic: Swift
        // randomises dictionary iteration per process, so in the ordinary
        // A-B-A-B-C shape — where verse and chorus BOTH occur twice — the
        // same song came back labelled 절 1 / 후렴 on one run and
        // 후렴 / 섹션 B on the next. The tie is the common case, so break it
        // on purpose: prefer the progression that is not the song's opening
        // phrase, because a chorus is what a verse leads to.
        let chorusGroup = counts
            .filter { $0.value > 1 }
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                if (a.key == firstGroup) != (b.key == firstGroup) {
                    return b.key == firstGroup
                }
                return (order[a.key] ?? 0) < (order[b.key] ?? 0)
            }
            .first?.key

        var sections: [SongSection] = []
        var verseNumber = 0
        for (position, chunk) in chunks.enumerated() {
            guard let first = chunk.first, let last = chunk.last else { continue }
            let group = groupOf[position]
            let letter = letterFor[group] ?? "A"

            // NOT merged into an identical neighbour.
            //
            // Merging adjacent chunks of the same letter destroyed the thing
            // the map exists to show: when the repeating unit is the whole
            // verse-chorus pair, the two passes through it are adjacent and
            // identical, so merging turned A A B into one long A and a B —
            // a five-part song reported as two. Two passes through the same
            // part ARE two passes, and seeing them twice is the point.

            let label: String
            if group == chorusGroup {
                label = "후렴"
            } else if group == firstGroup {
                verseNumber += 1
                label = "절 \(verseNumber)"
            } else {
                label = "섹션 \(letter)"
            }

            sections.append(SongSection(
                patternKey: letter,
                label: label,
                startIndex: first.startIndex,
                endIndex: last.endIndex,
                startTime: first.start
            ))
        }
        return sections
    }

    // MARK: - Phrase length

    /// Picks the phrase length to chunk on.
    ///
    /// Scores each candidate by how many chords are explained by a
    /// progression that occurs more than once — now by SIMILARITY rather
    /// than exact equality, so a phrase with one chord misheard still counts
    /// as a repeat of itself.
    ///
    /// Ties are common and matter: in a typical verse-chorus song, units of
    /// 2, 4 and 8 all score identically, because a repeating 8-chord block
    /// also repeats at 4 and at 2. Taking the shortest chops the song into
    /// meaningless two-chord fragments, and the longest swallows verse and
    /// chorus into one block. So among the tied winners, prefer the shortest
    /// multiple of four — the phrase length worship and pop writing
    /// overwhelmingly use.
    private static func bestRepeatingUnit(_ keys: [Int]) -> (unit: Int, offset: Int) {
        let maxUnit = min(16, max(2, keys.count / 2))
        guard maxUnit >= 2 else { return (4, 0) }

        // FOUR-CHORD PHRASES FIRST.
        //
        // Scoring every unit together does not work, because a shorter unit
        // trivially explains more: two-chord blocks repeat all over a song
        // that has no two-chord phrase in it, and A-B-A-B-C-B came back as
        // twelve sections of two chords each. Normalising the score does not
        // fix it either — the bias is real, not an artefact.
        //
        // So the domain decides: worship and pop harmony is written in
        // four-chord phrases, and those are the only lengths considered
        // unless none of them explains anything at all. The fallback matters
        // for the case that forced it — a verse ending on the chord its
        // chorus begins on merges at the seam and leaves phrases of 4, 3, 4,
        // 3, so nothing lands on a multiple of four and the real period is 7.
        let preferred = stride(from: 4, through: maxUnit, by: 4).map { $0 }
        if let found = search(keys, units: preferred) { return found }
        return search(keys, units: Array(2...maxUnit)) ?? (4, 0)
    }

    private static func search(_ keys: [Int], units: [Int]) -> (unit: Int, offset: Int)? {
        var best = 0
        var bestUnit = 0
        var bestOffset = 0

        for unit in units where unit >= 2 {
            for offset in 0..<unit {
                var blocks: [[Int]] = []
                var index = offset
                while index + unit <= keys.count {
                    blocks.append(Array(keys[index..<(index + unit)]))
                    index += unit
                }
                guard blocks.count > 1 else { continue }

                var explained = 0
                for (i, block) in blocks.enumerated() {
                    let repeats = blocks.enumerated().contains { j, other in
                        j != i && similarity(block, other) >= sameSectionThreshold
                    }
                    if repeats { explained += unit }
                }
                guard explained > 0 else { continue }

                // Shorter wins a tie, and a multiple of four wins before
                // that: in a verse-chorus song, units of 2, 4 and 8 all
                // explain the same chords, because a repeating 8-chord block
                // also repeats at 4 and at 2. The shortest chops the song
                // into meaningless fragments; the longest swallows verse and
                // chorus into one block and reports a two-part song as one.
                // Four is the phrase length worship and pop writing
                // overwhelmingly use.
                // Most explained wins; on a tie the shorter unit, because
                // the longer one swallows verse and chorus into a single
                // block and reports a two-part song as one.
                let better: Bool
                if explained != best {
                    better = explained > best
                } else if unit != bestUnit {
                    better = unit < bestUnit
                } else {
                    better = offset < bestOffset
                }
                if better { best = explained; bestUnit = unit; bestOffset = offset }
            }
        }

        guard best > 0, bestUnit > 0 else { return nil }
        return (bestUnit, bestOffset)
    }
}
