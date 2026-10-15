//
//  LyricCheck.swift
//  SolaPraise
//
//  The 코드표's lyrics checked against the lyrics a YouTube upload of the
//  song prints in its description — line by line, syllable by syllable.
//
//  WHY: a recogniser that misreads 「며」 as 「묘」 or drops a line does so
//  silently; the 코드표 just reads wrong. Teams very often paste the lyrics
//  into a video's description, and that is the only source used here —
//  nothing is fetched from a lyrics site, and nothing is kept.
//
//  How: the description's lyric lines become one run of syllables. Each
//  line of the 코드표 is found in it where it fits best (an alignment that
//  may start and end anywhere in the run), and every syllable that does not
//  agree is marked, with what the description has there. A line that fits
//  nowhere is reported as not found — a description often carries only the
//  first verse.
//
//  Foundation only: Tools/check-lyric-check.swift runs it.
//

import Foundation

enum LyricCheck {

    struct Line: Equatable {
        /// The 코드표's syllables, as shown.
        let syllables: [String]
        /// Indices of `syllables` the description disagrees with.
        let differs: Set<Int>
        /// The description's text where the line was found; nil when it was
        /// found nowhere.
        let reference: String?

        var found: Bool { reference != nil }
        var agrees: Bool { found && differs.isEmpty }
    }

    /// Each 코드표 line against the description's lyrics.
    static func compare(lines: [[String]], referenceLines: [String]) -> [Line] {
        let reference = Array(referenceLines.joined().filter { !$0.isWhitespace && !$0.isPunctuation })
        return lines.map { compare(line: $0, reference: reference) }
    }

    static func compare(line syllables: [String], reference: [Character]) -> Line {
        // One character per syllable for Korean; a Latin word stays whole
        // and is checked as its letters.
        var chars: [Character] = []
        var owner: [Int] = []
        for (index, syllable) in syllables.enumerated() {
            for c in syllable where !c.isWhitespace && !c.isPunctuation {
                chars.append(c)
                owner.append(index)
            }
        }
        guard !chars.isEmpty, !reference.isEmpty else {
            return Line(syllables: syllables, differs: [], reference: nil)
        }
        let n = chars.count, m = reference.count
        // cost[i][j]: the first i chart characters against reference ending
        // at j, starting anywhere.
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { cost[i][0] = i }
        for i in 1...n {
            for j in 1...m {
                let same = chars[i - 1] == reference[j - 1] ? 0 : 1
                cost[i][j] = min(cost[i - 1][j - 1] + same, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
        var end = 1
        // On a tie, the later end: a misread last syllable is a syllable
        // that differs, not one the description lacks.
        for j in 1...m where cost[n][j] < cost[n][end] || (cost[n][j] == cost[n][end] && j == end + 1) {
            end = j
        }
        // A line more than a third wrong is not this line at all.
        guard Double(cost[n][end]) <= Double(n) / 3 else {
            return Line(syllables: syllables, differs: [], reference: nil)
        }
        var differs = Set<Int>()
        var i = n, j = end
        while i > 0 {
            if j > 0, cost[i][j] == cost[i - 1][j - 1] + (chars[i - 1] == reference[j - 1] ? 0 : 1) {
                if chars[i - 1] != reference[j - 1] { differs.insert(owner[i - 1]) }
                i -= 1; j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                differs.insert(owner[i - 1])   // not in the description
                i -= 1
            } else {
                // The description has a syllable the 코드표 dropped: marked
                // on the syllable before the gap.
                differs.insert(owner[max(0, i - 1)])
                j -= 1
            }
        }
        return Line(syllables: syllables, differs: differs, reference: String(reference[j..<end]))
    }
}
