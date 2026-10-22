//
//  check-chordpro.swift
//  SolaPraise
//
//  Checks the 코드표 as ChordPro: each verse its own section with its own
//  chords, syllables made into words, a chord set before the syllable it
//  is played on — inside a word too — a refrain written once and named
//  after, an instrumental staff as chords alone. Words here are made up.
//
//  WHY THIS EXISTS: a chord a syllable off, or a verse's words under
//  another verse's chords, is what the band plays from. Neither looks
//  wrong until someone sings it.
//
//  Run:
//      swiftc -O -o /tmp/chordpro \
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ScoreRecognition.swift Sources/Chords/ChordGlyphs.swift \
//          Sources/Chords/ScoreChart.swift Sources/Chords/LyricSpacing.swift Sources/Chords/ChordProSheet.swift \
//          Tools/check-chordpro.swift
//      /tmp/chordpro
//

import Foundation

@main
struct CheckChordPro {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message):\n\(got)") }
        }
        let g = UUID(), c = UUID(), d = UUID(), e = UUID()
        let names = [g: "G", c: "C", d: "D", e: "Em"]
        func cell(_ chord: UUID?, _ syllables: String...) -> ScoreChart.Cell {
            ScoreChart.Cell(chord: chord, syllables: syllables)
        }
        func bar(_ cells: ScoreChart.Cell...) -> ScoreChart.Bar {
            ScoreChart.Bar(segments: [], cells: cells)
        }
        // Two verses under one staff; the second staff's words once.
        let verses = ScoreChart.System(bars: [
            bar(cell(g, "하", "바"), cell(nil, "늘", "다"), cell(c, "노", "노")),
            bar(cell(nil, "래", "래"), cell(d, "", ""))
        ], verses: 2)
        let refrain = ScoreChart.System(bars: [
            bar(cell(e, "주", ""), cell(nil, "님", "")), bar(cell(c, "찬", ""), cell(nil, "양", ""))
        ], verses: 1)
        let intro = ScoreChart.System(bars: [bar(cell(g, "")), bar(cell(d, ""))], verses: 1)

        let song = ChordProSheet.song(systems: [intro, verses, refrain], chord: { names[$0] }, title: "시험 노래", key: "G")
        expect(song.sections.map(\.label), ["1절", "후렴", "2절", "후렴"], "each verse, the refrain once and named again")
        expect(song.sections.map(\.kind), [.verse, .chorus, .verse, .chorusAgain], "kinds")
        expect(song.sections[0].lines.first?.isInstrumental, true, "the intro with the first verse, chords alone")
        expect(song.sections[2].lines.count, 1, "the intro not repeated in the second verse")

        let text = ChordProSheet.text(song)
        expect(text.contains("{title: 시험 노래}\n{key: G}"), true, "title and key")
        expect(text.contains("{start_of_verse: 1절}\n[G] [D]\n[G]하늘 [C]노래 [D]\n{end_of_verse}"), true,
               "verse 1: its words, chords before their syllables, a held chord on its own")
        expect(text.contains("{start_of_verse: 2절}\n[G]바다 [C]노래 [D]\n{end_of_verse}"), true, "verse 2: its own words under the same chords")
        expect(text.contains("{start_of_chorus: 후렴}\n[Em]주님 [C]찬양\n{end_of_chorus}"), true, "the refrain once")
        expect(text.contains("{chorus: 후렴}"), true, "and named after the second verse")

        // A chord that changes inside a word.
        let inside = ScoreChart.System(bars: [bar(cell(g, "사"), cell(c, "랑"), cell(nil, "해"))], verses: 1)
        let one = ChordProSheet.song(systems: [inside], chord: { names[$0] })
        expect(ChordProSheet.text(one), "[G]사[C]랑해\n", "inside a word, one verse, no labels")

        if failures == 0 {
            print("all chordpro checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
