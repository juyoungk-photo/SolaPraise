//
//  check-lyric-fixes.swift
//  SolaPraise
//
//  Checks lyric corrections on the 코드표: kept, laid over a reading, and
//  left alone where the reading has changed.
//
//  WHY THIS EXISTS: a correction that lands on the wrong syllable puts a
//  word where nobody sings it, and one that silently drops after a chord
//  is moved makes the fix look as if it never saved. Neither shows until
//  the page is in front of somebody on Sunday.
//
//  The syllables here are made up — never a song's real words.
//
//  Run:
//      swiftc -O -o /tmp/lyricfixes \
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ScoreRecognition.swift Sources/Chords/ChordGlyphs.swift Sources/Chords/ScoreChart.swift \
//          Sources/Chords/LyricFixes.swift Tools/check-lyric-fixes.swift
//      /tmp/lyricfixes
//

import Foundation

@main
struct CheckLyricFixes {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }

        func cell(_ syllables: String...) -> ScoreChart.Cell {
            ScoreChart.Cell(chord: nil, syllables: syllables)
        }
        func line(_ bars: [[ScoreChart.Cell]], verses: Int = 2) -> ScoreChart.System {
            ScoreChart.System(bars: bars.map { ScoreChart.Bar(segments: [], cells: $0) }, verses: verses)
        }
        func text(_ system: ScoreChart.System, verse: Int) -> String {
            system.bars.flatMap(\.cells).map { $0.syllables.indices.contains(verse) ? $0.syllables[verse] : "" }
                .joined(separator: "|")
        }

        // Two verses, two bars; the reader took 「다」 for 「타」 in verse 1.
        let read = line([[cell("가", "마"), cell("나", "바")], [cell("타", "사"), cell("라", "")]])

        // 1. One syllable corrected.
        var edited = read
        edited.bars[1].cells[0].syllables[0] = "다"
        var fixes = LyricFixes.merge([], system: 0, shown: read, edited: edited)
        expect(fixes == [LyricFix(system: 0, bar: 1, cell: 0, verse: 0, from: "타", to: "다")],
               "one fix kept: \(fixes)")
        var shown = LyricFixes.apply(fixes, to: [read])[0]
        expect(text(shown, verse: 0) == "가|나|다|라", "fix laid over the reading: \(text(shown, verse: 0))")
        expect(text(shown, verse: 1) == "마|바|사|", "the other verse untouched: \(text(shown, verse: 1))")

        // 2. Corrected again: still from what was read, not from the first fix.
        edited = shown
        edited.bars[1].cells[0].syllables[0] = "더"
        fixes = LyricFixes.merge(fixes, system: 0, shown: shown, edited: edited)
        expect(fixes == [LyricFix(system: 0, bar: 1, cell: 0, verse: 0, from: "타", to: "더")],
               "a second fix replaces the first: \(fixes)")

        // 3. Put back as read: the fix goes.
        shown = LyricFixes.apply(fixes, to: [read])[0]
        edited = shown
        edited.bars[1].cells[0].syllables[0] = "타"
        fixes = LyricFixes.merge(fixes, system: 0, shown: shown, edited: edited)
        expect(fixes.isEmpty, "a fix undone by hand is dropped: \(fixes)")

        // 4. A syllable added where the reader saw none, past the verses it kept.
        let short = line([[ScoreChart.Cell(chord: nil, syllables: ["가"])]])
        edited = short
        edited.bars[0].cells[0].syllables = ["가", "하"]
        fixes = LyricFixes.merge([], system: 0, shown: short, edited: edited)
        expect(fixes == [LyricFix(system: 0, bar: 0, cell: 0, verse: 1, from: "", to: "하")],
               "added in a verse the cell lacked: \(fixes)")
        expect(text(LyricFixes.apply(fixes, to: [short])[0], verse: 1) == "하", "added syllable shown")

        // 5. Read again and the reader now gets it right, or lines up
        // differently: the fix does not land on another syllable.
        let fix = [LyricFix(system: 0, bar: 1, cell: 0, verse: 0, from: "타", to: "다")]
        let rightNow = line([[cell("가", "마"), cell("나", "바")], [cell("다", "사"), cell("라", "")]])
        expect(LyricFixes.apply(fix, to: [rightNow]) == [rightNow], "a reading now right is left alone")
        let shifted = line([[cell("가", "마")], [cell("나", "바"), cell("타", "사")]])
        expect(LyricFixes.apply(fix, to: [shifted]) == [shifted], "a shifted reading is left alone")
        // A line or bar that is no longer there.
        expect(LyricFixes.apply([LyricFix(system: 3, bar: 0, cell: 0, verse: 0, from: "", to: "가")], to: [read]) == [read],
               "a fix for a missing line is skipped")

        // 6. Fixes on another line stay when this one is edited.
        let other = [LyricFix(system: 1, bar: 0, cell: 0, verse: 0, from: "아", to: "어")]
        edited = read
        edited.bars[0].cells[1].syllables[1] = "버"
        fixes = LyricFixes.merge(other, system: 0, shown: read, edited: edited)
        expect(fixes.count == 2 && fixes.contains(other[0]), "other lines' fixes kept: \(fixes)")

        if failures == 0 {
            print("all lyric fix checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
