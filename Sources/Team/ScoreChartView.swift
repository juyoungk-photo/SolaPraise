//
//  ScoreChartView.swift
//  SolaPraise
//
//  The stand's 코드표: a score read as lines of lyrics with each chord over
//  the syllable it falls on, in the key the stand is showing.
//
//  WHY LINES, NOT A GRID OF BARS: the first version put each bar in a box
//  and the words of each chord in a column of their own. A singer got
//  「당할 E 때」 — a phrase cut into pieces, one verse stacked under another
//  in narrow columns — and could not sing from it. Now each staff of the
//  score is a line of text that flows across the screen: syllables side by
//  side, every verse's syllable under the same note, as in a hymnal; the
//  chord sits above its syllable and runs to the right instead of pushing
//  the words apart; a bar is a thin line between syllables, not a box.
//
//  WORDS, THEN BARS: the lyrics are spaced as Korean is written
//  (LyricSpacing) and a line wraps only between words; a bar line is a thin
//  mark in the chord row, so it no longer cuts a word in two.
//
//  Same on both devices; a phone wraps the line sooner.
//

import SwiftUI
import UIKit

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

struct ScoreChartView: View {
    let systems: [ScoreChart.System]
    /// The chord as it should read now — transposed, spelled — by id; nil
    /// for a chord the reader has since removed.
    let chord: (UUID) -> String?
    let scale: CGFloat
    /// How much room the lyrics get, apart from their size: 1 as first
    /// drawn, more to space syllables, words and lines further apart.
    var spacing: CGFloat = 1

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Larger on an iPad, which stands further away and has the width.
    private var deviceScale: CGFloat { sizeClass == .regular ? 1.4 : 1 }
    private var chordFont: Font { .system(size: 20 * scale * deviceScale, weight: .bold, design: .rounded) }
    /// A little under the chords: Hangul at the same point size reads
    /// larger than a Latin capital, and the lyrics crowded out the chords.
    private var lyricSize: CGFloat { 17 * scale * deviceScale }
    private var chordRowHeight: CGFloat { 26 * scale * deviceScale }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(systems.enumerated()), id: \.offset) { index, system in
                    // WHY CLOSE, THEN APART: some scores set two parts'
                    // words under one chord line — the second staff has no
                    // chords of its own and is sung with the one above. It
                    // sits close under it, its empty chord row shrunk to the
                    // bar marks; a line with chords starts a new group.
                    let chorded = Self.hasChords(system)
                    line(system, index: index, rowHeight: chorded ? chordRowHeight : chordRowHeight * 0.35)
                        .padding(.top, index == 0 ? 0 : (chorded ? 34 : 6) * spacing)
                }
                Text("악보에서 읽은 코드와 가사입니다. 틀린 글자가 있을 수 있으니 악보와 함께 확인하세요.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
    }

    // MARK: - One staff, as a line

    /// One sung position as drawn: the cell, its syllables as they should
    /// read (spaced and corrected — LyricSpacing), and what sits around it.
    private struct Slot {
        let cell: ScoreChart.Cell
        var syllables: [String]
        /// A bar starts here: a mark in the chord row, before it.
        var barBefore = false
        var repeatStart = false
        var repeatEndBefore = false
        /// The number of the repeat that starts here, ①.
        var startNumber: Int?
        /// Where the repeat that ends just before this goes back to: its
        /// number, or 0 for the beginning.
        var returnTo: Int?
        /// Space after it so the chord over it has finished before the next
        /// chord — an extender line when that falls inside a word.
        var room: CGFloat = 0
        /// A space after it: some verse starts a word on the next note.
        var gapAfter: CGFloat = 0
        /// By verse: the word goes on into the next note.
        var continues: [Bool] = []

        func continues(_ verse: Int) -> Bool { verse < continues.count && continues[verse] }
    }

    private enum Token {
        case verseNumbers(Int)
        /// A word: drawn as one piece, so a line wraps only between words.
        case word([Slot])
        case repeatEnd(returnTo: Int?)
    }

    /// The staff as words, in the order sung.
    ///
    /// WHY WORDS, NOT BARS: a bar ends wherever the music says, mid-word as
    /// often as not. Laid out bar by bar, 「찬양하며 경배해」 read 「하며경 |
    /// 배해귀」 — a sentence nobody wrote. The words come from the language
    /// (LyricSpacing), the bars stay as thin marks in the chord row, and
    /// the line breaks only where a word ends.
    private static func hasChords(_ system: ScoreChart.System) -> Bool {
        system.bars.contains { bar in bar.cells.contains { $0.chord != nil } }
    }

    // MARK: - Repeats, numbered

    /// Each repeat numbered in reading order — ① where it starts, 「↩①」
    /// where it ends — so a chart with several says which end goes back
    /// where. An end with no start before it goes back to the beginning.
    private var repeats: (starts: [String: Int], returns: [String: Int]) {
        var starts: [String: Int] = [:], returns: [String: Int] = [:]
        var count = 0
        var open: [Int] = []
        for (s, system) in systems.enumerated() {
            for (b, bar) in system.bars.enumerated() {
                if bar.repeatStart {
                    count += 1
                    starts["\(s)-\(b)"] = count
                    open.append(count)
                }
                if bar.repeatEnd { returns["\(s)-\(b)"] = open.popLast() ?? 0 }
            }
        }
        return (starts, returns)
    }

    static func repeatLabel(_ number: Int) -> String {
        guard number > 0 else { return "처음" }
        return number <= 20 ? String(UnicodeScalar(0x2460 + UInt32(number - 1))!) : "\(number)"
    }

    private func line(_ system: ScoreChart.System, index systemIndex: Int, rowHeight: CGFloat) -> some View {
        let numbering = repeats
        let verses = max(system.verses, 1)
        let empty = ScoreChart.Cell(chord: nil, syllables: Array(repeating: "", count: verses))

        // Every cell in order, with the bar it opens.
        var slots: [Slot] = []
        for (index, bar) in system.bars.enumerated() {
            let cells = bar.cells.isEmpty ? [empty] : bar.cells
            for (offset, cell) in cells.enumerated() {
                var slot = Slot(cell: cell, syllables: cell.syllables)
                if offset == 0 {
                    slot.barBefore = index > 0 || bar.repeatStart
                    slot.repeatStart = bar.repeatStart
                    slot.repeatEndBefore = index > 0 && system.bars[index - 1].repeatEnd
                    slot.startNumber = numbering.starts["\(systemIndex)-\(index)"]
                    if index > 0 { slot.returnTo = numbering.returns["\(systemIndex)-\(index - 1)"] }
                }
                slots.append(slot)
            }
        }

        // Spacing and corrections, verse by verse.
        var starts = [[Bool]](repeating: [Bool](repeating: false, count: slots.count), count: verses)
        for verse in 0..<verses {
            let indices = slots.indices.filter { verse < slots[$0].syllables.count && !slots[$0].syllables[verse].isEmpty }
            let spaced = LyricSpacing.space(indices.map { slots[$0].syllables[verse] })
            for (k, index) in indices.enumerated() {
                slots[index].syllables[verse] = spaced.syllables[k]
                starts[verse][index] = spaced.startsWord[k]
            }
        }
        // A chord over no syllable is a word of its own.
        var wordless = [Bool](repeating: false, count: slots.count)
        for index in slots.indices where slots[index].syllables.allSatisfy(\.isEmpty) {
            wordless[index] = true
            for verse in 0..<verses {
                starts[verse][index] = true
                if index + 1 < slots.count { starts[verse][index + 1] = true }
            }
        }

        // WHY A GAP WHEREVER ANY VERSE HAS ONE, AND A HYPHEN: the verses
        // share their notes, not their words — 「나의 노래」 over 「주님께서」.
        // Every verse gets its spaces where it has them; a verse whose word
        // runs on through another verse's space shows a hyphen there, as a
        // hymnal does, so a gap never reads as a space it does not have.
        // The line wraps only where the first verse's words end.
        let lead = (0..<verses).first { verse in slots.contains { verse < $0.syllables.count && !$0.syllables[verse].isEmpty } } ?? 0
        for i in slots.indices where i + 1 < slots.count {
            guard (0..<verses).contains(where: { starts[$0][i + 1] }) else { continue }
            slots[i].gapAfter = wordGap
            slots[i].continues = (0..<verses).map { verse in
                !starts[verse][i + 1]
                    && verse < slots[i].syllables.count && !slots[i].syllables[verse].isEmpty
                    && verse < slots[i + 1].syllables.count && !slots[i + 1].syllables[verse].isEmpty
            }
        }
        for i in slots.indices where i + 1 < slots.count && slots[i].gapAfter == 0 {
            slots[i].continues = [Bool](repeating: true, count: verses)
        }

        // A chord runs to the right over the syllables after it. Only where
        // it would reach the next chord does the line open up — by exactly
        // the overlap, just before that next chord's syllable.
        var widths = slots.map { cellWidth($0.cell, $0.syllables) + syllableGap + $0.gapAfter }
        for i in slots.indices {
            guard let id = slots[i].cell.chord, let name = chord(id) else { continue }
            let need = textWidth(name, chordSize, bold: true) + 8
            guard let next = slots.indices.first(where: { $0 > i && slots[$0].cell.chord != nil }) else { continue }
            let available = widths[i..<next].reduce(0, +)
            if need > available {
                slots[next - 1].room += need - available
                widths[next - 1] += need - available
            }
        }

        var tokens: [Token] = []
        if system.verses > 1 { tokens.append(.verseNumbers(system.verses)) }
        var word: [Slot] = []
        for (index, slot) in slots.enumerated() {
            if index > 0, starts[lead][index] || wordless[index] || wordless[index - 1], !word.isEmpty {
                tokens.append(.word(word))
                word = []
            }
            word.append(slot)
        }
        if !word.isEmpty { tokens.append(.word(word)) }
        if system.bars.last?.repeatEnd == true {
            tokens.append(.repeatEnd(returnTo: numbering.returns["\(systemIndex)-\(system.bars.count - 1)"]))
        }

        return LineFlow(lineSpacing: 12 * spacing) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case let .verseNumbers(count):
                    verseNumbers(count, rowHeight: rowHeight)
                case let .word(slots):
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                            slotView(slot, verses: verses, rowHeight: rowHeight)
                        }
                    }
                case .repeatEnd(let returnTo):
                    barMark(verses: verses, rowHeight: rowHeight, repeatStart: false, repeatEnd: true)
                        .overlay(alignment: .top) {
                            if let returnTo { repeatBadge("↩" + Self.repeatLabel(returnTo)).offset(y: -rowHeight * 0.55) }
                        }
                }
            }
        }
    }

    /// Room between words: a space as the singer reads it.
    private var wordGap: CGFloat { lyricSize * 0.65 * spacing }
    /// Room after every syllable, beyond its own width.
    private var syllableGap: CGFloat { lyricSize * 0.3 * max(0, spacing - 1) }
    /// One verse's row, line to line.
    private var verseRow: CGFloat { lyricSize * (1.25 + 0.3 * max(0, spacing - 1)) }

    private var chordSize: CGFloat { 20 * scale * deviceScale }

    /// The width a cell's syllables take — its widest verse — or, for a
    /// chord with no words under it, the chord itself.
    private func cellWidth(_ cell: ScoreChart.Cell, _ syllables: [String]) -> CGFloat {
        let widest = syllables.enumerated().map { verse, text in
            textWidth(text, lyricSize, bold: false)
                + (cell.isHeld(verse) && !text.isEmpty ? lyricSize * 0.71 : 0)
        }.max() ?? 0
        if widest == 0, let id = cell.chord, let name = chord(id) {
            return textWidth(name, chordSize, bold: true) + 8
        }
        return max(widest, textWidth(" ", lyricSize, bold: false))
    }

    private func textWidth(_ text: String, _ size: CGFloat, bold: Bool) -> CGFloat {
        let font: UIFont = bold
            ? UIFont.systemFont(ofSize: size, weight: .bold).withDesign(.rounded)
            : UIFont.systemFont(ofSize: size)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func slotView(_ slot: Slot, verses: Int, rowHeight: CGFloat) -> some View {
        let name = slot.cell.chord.flatMap(chord)
        let wordless = slot.syllables.allSatisfy(\.isEmpty)
        return VStack(alignment: .leading, spacing: 2) {
            Group {
                if let name, wordless {
                    // In the flow: it widens its column rather than collide.
                    Text(name).font(chordFont).fixedSize().padding(.trailing, 8)
                } else {
                    Color.clear.frame(width: 1)
                        .overlay(alignment: .leading) {
                            if let name { Text(name).font(chordFont).fixedSize() }
                        }
                }
            }
            .frame(height: rowHeight, alignment: .bottomLeading)
            .foregroundStyle(Color.accentColor)

            ForEach(0..<verses, id: \.self) { verse in
                let syllable = verse < slot.syllables.count ? slot.syllables[verse] : ""
                HStack(spacing: 0) {
                    Text(syllable.isEmpty ? " " : syllable)
                        .font(.system(size: verse == 0 ? lyricSize : lyricSize * 0.92))
                        .fixedSize()
                    // Held over the notes after it, as the score marks it
                    // with a dash: 「하—며—」. Splitting a word this way is
                    // how a singer reads a long note; it never joins two.
                    if slot.cell.isHeld(verse), !syllable.isEmpty {
                        Rectangle()
                            .frame(width: lyricSize * 0.55, height: 1.5)
                            .padding(.horizontal, lyricSize * 0.08)
                            .opacity(0.45)
                    }
                    // Room for a long chord inside a word: an extender, so
                    // the gap does not read as a space between two words.
                    if slot.room > 0 {
                        if slot.continues(verse), !syllable.isEmpty {
                            Rectangle()
                                .frame(width: max(slot.room - 2, lyricSize * 0.28), height: 1.5)
                                .padding(.horizontal, 1)
                                .opacity(0.45)
                        } else {
                            Color.clear.frame(width: slot.room)
                        }
                    }
                    // Another verse's space, inside this verse's word.
                    if slot.gapAfter > 0 {
                        ZStack {
                            if slot.continues(verse), !syllable.isEmpty {
                                Rectangle().frame(width: lyricSize * 0.28, height: 1.5).opacity(0.45)
                            }
                        }
                        .frame(width: slot.gapAfter)
                    }
                }
                .foregroundStyle(.white.opacity(verse == 0 ? 0.95 : 0.72))
                .frame(height: verseRow, alignment: .leading)
            }
        }
        .padding(.trailing, syllableGap)
        // The bar that starts here: a thin mark in the chord row, just
        // before the syllable — the lyrics under it run on.
        .overlay(alignment: .topLeading) {
            if slot.barBefore {
                barTick(repeatStart: slot.repeatStart, repeatEnd: slot.repeatEndBefore, rowHeight: rowHeight)
                    .offset(x: -4)
                    // Above the bar line: where a repeat starts, its number;
                    // where one ends, where it goes back to.
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 3) {
                            if let back = slot.returnTo { repeatBadge("↩" + Self.repeatLabel(back)) }
                            if let number = slot.startNumber { repeatBadge(Self.repeatLabel(number)) }
                        }
                        .fixedSize()
                        .offset(x: -2, y: -rowHeight * 0.55)
                    }
            }
        }
    }

    private func repeatBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: max(11, lyricSize * 0.6), weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .background(Capsule().fill(.white.opacity(0.85)))
    }

    /// A bar line in the chord row only.
    private func barTick(repeatStart: Bool, repeatEnd: Bool, rowHeight: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(repeatStart || repeatEnd ? 0.75 : 0.3))
            .frame(width: repeatStart || repeatEnd ? 3 : 1, height: rowHeight * 0.8)
            .padding(.top, rowHeight * 0.1)
            .accessibilityHidden(true)
    }

    private func barMark(verses: Int, rowHeight: CGFloat, repeatStart: Bool, repeatEnd: Bool) -> some View {
        HStack(spacing: 2) {
            if repeatEnd { repeatDots }
            Rectangle()
                .fill(.white.opacity(repeatStart || repeatEnd ? 0.75 : 0.25))
                .frame(width: repeatStart || repeatEnd ? 3 : 1)
            if repeatStart { repeatDots }
        }
        .frame(height: rowHeight + 2 + CGFloat(verses) * (verseRow + 2))
        .padding(.horizontal, 7)
    }

    private var repeatDots: some View {
        VStack(spacing: 6) {
            Circle().frame(width: 4, height: 4)
            Circle().frame(width: 4, height: 4)
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    private func verseNumbers(_ count: Int, rowHeight: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Color.clear.frame(width: 1, height: rowHeight)
            ForEach(1...count, id: \.self) { verse in
                Text("\(verse).")
                    .font(.system(size: lyricSize * 0.8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: verseRow)
            }
        }
        .padding(.trailing, 8)
    }

    /// Left to right at natural widths, wrapping to the next line when the
    /// next item does not fit; items share a top edge.
    private struct LineFlow: Layout {
        var lineSpacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            arrange(subviews, width: proposal.width ?? .infinity).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let placed = arrange(subviews, width: bounds.width)
            for (index, origin) in placed.origins.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                      proposal: .unspecified)
            }
        }

        private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
            var origins: [CGPoint] = []
            var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > width {
                    x = 0
                    y += lineHeight + lineSpacing
                    lineHeight = 0
                }
                origins.append(CGPoint(x: x, y: y))
                x += size.width
                lineHeight = max(lineHeight, size.height)
                widest = max(widest, x)
            }
            return (origins, CGSize(width: min(widest, width), height: y + lineHeight))
        }
    }
}
