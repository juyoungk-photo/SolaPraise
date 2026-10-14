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

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Larger on an iPad, which stands further away and has the width.
    private var deviceScale: CGFloat { sizeClass == .regular ? 1.4 : 1 }
    private var chordFont: Font { .system(size: 20 * scale * deviceScale, weight: .bold, design: .rounded) }
    private var lyricSize: CGFloat { 19 * min(scale, 1.4) * deviceScale }
    private var chordRowHeight: CGFloat { 26 * scale * deviceScale }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(Array(systems.enumerated()), id: \.offset) { _, system in
                    line(system)
                }
                Text("악보에서 읽은 코드와 가사입니다. 틀린 글자가 있을 수 있으니 악보와 함께 확인하세요.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - One staff, as a line

    /// One sung position as drawn: the cell, its syllables as they should
    /// read (spaced and corrected — LyricSpacing), and what sits around it.
    private struct Slot {
        let cell: ScoreChart.Cell
        let syllables: [String]
        /// A bar starts here: a mark in the chord row, before it.
        var barBefore = false
        var repeatStart = false
        var repeatEndBefore = false
        /// Space after it so the chord over it has finished before the next
        /// chord — an extender line when that falls inside a word.
        var room: CGFloat = 0
    }

    private enum Token {
        case verseNumbers(Int)
        /// A word: drawn as one piece, so a line wraps only between words.
        case word([Slot])
        case repeatEnd
    }

    /// The staff as words, in the order sung.
    ///
    /// WHY WORDS, NOT BARS: a bar ends wherever the music says, mid-word as
    /// often as not. Laid out bar by bar, 「찬양하며 경배해」 read 「하며경 |
    /// 배해귀」 — a sentence nobody wrote. The words come from the language
    /// (LyricSpacing), the bars stay as thin marks in the chord row, and
    /// the line breaks only where a word ends.
    private func line(_ system: ScoreChart.System) -> some View {
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
                }
                slots.append(slot)
            }
        }

        // Spacing and corrections, verse by verse; a word starts wherever
        // any verse starts one.
        var startsWord = [Bool](repeating: false, count: slots.count)
        for verse in 0..<verses {
            let indices = slots.indices.filter { verse < slots[$0].syllables.count && !slots[$0].syllables[verse].isEmpty }
            let spaced = LyricSpacing.space(indices.map { slots[$0].syllables[verse] })
            for (k, index) in indices.enumerated() {
                var syllables = slots[index].syllables
                syllables[verse] = spaced.syllables[k]
                slots[index] = Slot(cell: slots[index].cell, syllables: syllables, barBefore: slots[index].barBefore,
                                    repeatStart: slots[index].repeatStart, repeatEndBefore: slots[index].repeatEndBefore)
                if spaced.startsWord[k] { startsWord[index] = true }
            }
        }
        // A chord over no syllable is a word of its own.
        for index in slots.indices where slots[index].syllables.allSatisfy(\.isEmpty) {
            startsWord[index] = true
            if index + 1 < slots.count { startsWord[index + 1] = true }
        }

        // A chord runs to the right over the syllables after it. Only where
        // it would reach the next chord does the line open up — by exactly
        // the overlap, just before that next chord's syllable.
        var widths = slots.map { cellWidth($0.cell, $0.syllables) }
        for i in slots.indices {
            guard let id = slots[i].cell.chord, let name = chord(id) else { continue }
            let need = textWidth(name, chordSize, bold: true) + 8
            guard let next = slots.indices.first(where: { $0 > i && slots[$0].cell.chord != nil }) else { continue }
            var available: CGFloat = 0
            for k in i..<next {
                available += widths[k]
                if k + 1 < slots.count, startsWord[k + 1] { available += wordGap }
            }
            if need > available {
                slots[next - 1].room += need - available
                widths[next - 1] += need - available
            }
        }

        var tokens: [Token] = []
        if system.verses > 1 { tokens.append(.verseNumbers(system.verses)) }
        var word: [Slot] = []
        for (index, slot) in slots.enumerated() {
            if startsWord[index], !word.isEmpty {
                tokens.append(.word(word))
                word = []
            }
            word.append(slot)
        }
        if !word.isEmpty { tokens.append(.word(word)) }
        if system.bars.last?.repeatEnd == true { tokens.append(.repeatEnd) }

        return LineFlow(lineSpacing: 12, itemSpacing: wordGap) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case let .verseNumbers(count):
                    verseNumbers(count)
                case let .word(slots):
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { offset, slot in
                            slotView(slot, verses: verses, insideWord: offset + 1 < slots.count)
                        }
                    }
                case .repeatEnd:
                    barMark(verses: verses, repeatStart: false, repeatEnd: true)
                }
            }
        }
    }

    /// Room between words: a space as the singer reads it.
    private var wordGap: CGFloat { lyricSize * 0.45 }

    private var chordSize: CGFloat { 20 * scale * deviceScale }

    /// The width a cell's syllables take — its widest verse — or, for a
    /// chord with no words under it, the chord itself.
    private func cellWidth(_ cell: ScoreChart.Cell, _ syllables: [String]) -> CGFloat {
        let widest = syllables.map { textWidth($0, lyricSize, bold: false) }.max() ?? 0
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

    private func slotView(_ slot: Slot, verses: Int, insideWord: Bool) -> some View {
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
            .frame(height: chordRowHeight, alignment: .bottomLeading)
            .foregroundStyle(Color.accentColor)

            ForEach(0..<verses, id: \.self) { verse in
                let syllable = verse < slot.syllables.count ? slot.syllables[verse] : ""
                HStack(spacing: 0) {
                    Text(syllable.isEmpty ? " " : syllable)
                        .font(.system(size: verse == 0 ? lyricSize : lyricSize * 0.92))
                        .fixedSize()
                    // Room for a long chord inside a word: an extender, so
                    // the gap does not read as a space between two words.
                    if slot.room > 0 {
                        if insideWord, !syllable.isEmpty {
                            Rectangle()
                                .frame(width: max(slot.room - 4, 2), height: 1)
                                .padding(.horizontal, 2)
                                .opacity(0.35)
                        } else {
                            Color.clear.frame(width: slot.room)
                        }
                    }
                }
                .foregroundStyle(.white.opacity(verse == 0 ? 0.95 : 0.72))
                .frame(height: lyricSize * 1.25, alignment: .leading)
            }
        }
        // The bar that starts here: a thin mark in the chord row, just
        // before the syllable — the lyrics under it run on.
        .overlay(alignment: .topLeading) {
            if slot.barBefore {
                barTick(repeatStart: slot.repeatStart, repeatEnd: slot.repeatEndBefore)
                    .offset(x: -4)
            }
        }
    }

    /// A bar line in the chord row only.
    private func barTick(repeatStart: Bool, repeatEnd: Bool) -> some View {
        Rectangle()
            .fill(.white.opacity(repeatStart || repeatEnd ? 0.75 : 0.3))
            .frame(width: repeatStart || repeatEnd ? 3 : 1, height: chordRowHeight * 0.8)
            .padding(.top, chordRowHeight * 0.1)
            .accessibilityHidden(true)
    }

    private func barMark(verses: Int, repeatStart: Bool, repeatEnd: Bool) -> some View {
        HStack(spacing: 2) {
            if repeatEnd { repeatDots }
            Rectangle()
                .fill(.white.opacity(repeatStart || repeatEnd ? 0.75 : 0.25))
                .frame(width: repeatStart || repeatEnd ? 3 : 1)
            if repeatStart { repeatDots }
        }
        .frame(height: chordRowHeight + 2 + CGFloat(verses) * (lyricSize * 1.25 + 2))
        .padding(.horizontal, 7)
    }

    private var repeatDots: some View {
        VStack(spacing: 6) {
            Circle().frame(width: 4, height: 4)
            Circle().frame(width: 4, height: 4)
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    private func verseNumbers(_ count: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Color.clear.frame(width: 1, height: chordRowHeight)
            ForEach(1...count, id: \.self) { verse in
                Text("\(verse).")
                    .font(.system(size: lyricSize * 0.8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: lyricSize * 1.25)
            }
        }
        .padding(.trailing, 8)
    }

    /// Left to right at natural widths, wrapping to the next line when the
    /// next item does not fit; items share a top edge.
    private struct LineFlow: Layout {
        var lineSpacing: CGFloat
        /// Space between items on a line — between words.
        var itemSpacing: CGFloat = 0

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
                x += size.width + itemSpacing
                lineHeight = max(lineHeight, size.height)
                widest = max(widest, x - itemSpacing)
            }
            return (origins, CGSize(width: min(widest, width), height: y + lineHeight))
        }
    }
}
