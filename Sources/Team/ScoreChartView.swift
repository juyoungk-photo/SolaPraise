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

    private enum Token {
        /// `room`: space added after the cell so the chord before the next
        /// one has finished — placed at a chord change, never mid-word.
        case cell(ScoreChart.Cell, room: CGFloat)
        case bar(repeatStart: Bool, repeatEnd: Bool)
        case verseNumbers(Int)
    }

    /// The staff's bars flattened into one run of syllables with bar marks
    /// between, wrapped to the width.
    private func line(_ system: ScoreChart.System) -> some View {
        let verses = max(system.verses, 1)
        let empty = ScoreChart.Cell(chord: nil, syllables: Array(repeating: "", count: verses))
        // A bar with nothing read in it still holds its place.
        let bars = system.bars.map { bar -> [ScoreChart.Cell] in bar.cells.isEmpty ? [empty] : bar.cells }
        let cells = bars.flatMap { $0 }

        // A chord runs to the right over the syllables after it, as on a
        // printed chart. Only where it would reach the next chord does the
        // line open up — by exactly the overlap, just before that next
        // chord's syllable. Measured, not guessed: a two-syllable rule
        // opened gaps inside words, and none let 「C#m」 run into 「F#」.
        let barWidth: CGFloat = 15
        var widths = cells.map { cellWidth($0) }
        var room = [CGFloat](repeating: 0, count: cells.count)
        var barBefore = [Bool](repeating: false, count: cells.count)
        var position = 0
        for (index, bar) in bars.enumerated() {
            if index > 0, position < cells.count { barBefore[position] = true }
            position += bar.count
        }
        for i in cells.indices {
            guard let id = cells[i].chord, let name = chord(id) else { continue }
            let need = textWidth(name, chordSize, bold: true) + 8
            guard let next = cells.indices.first(where: { $0 > i && cells[$0].chord != nil }) else { continue }
            var available: CGFloat = 0
            for k in i..<next { available += widths[k] + (k > i && barBefore[k] ? barWidth : 0) }
            if barBefore[next] { available += barWidth }
            if need > available {
                room[next - 1] += need - available
                widths[next - 1] += need - available
            }
        }

        var tokens: [Token] = []
        if system.verses > 1 { tokens.append(.verseNumbers(system.verses)) }
        var flat = 0
        for (index, bar) in system.bars.enumerated() {
            if index > 0 || bar.repeatStart {
                tokens.append(.bar(repeatStart: bar.repeatStart,
                                   repeatEnd: index > 0 && system.bars[index - 1].repeatEnd))
            }
            for cell in bars[index] {
                tokens.append(.cell(cell, room: room[flat]))
                flat += 1
            }
        }
        if system.bars.last?.repeatEnd == true { tokens.append(.bar(repeatStart: false, repeatEnd: true)) }

        return LineFlow(lineSpacing: 12) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case let .cell(cell, room):
                    cellView(cell, verses: verses)
                        .padding(.trailing, room)
                case let .bar(start, end):
                    barMark(verses: verses, repeatStart: start, repeatEnd: end)
                case let .verseNumbers(count):
                    verseNumbers(count)
                }
            }
        }
    }

    private var chordSize: CGFloat { 20 * scale * deviceScale }

    /// The width a cell's syllables take — its widest verse — or, for a
    /// chord with no words under it, the chord itself.
    private func cellWidth(_ cell: ScoreChart.Cell) -> CGFloat {
        let syllables = cell.syllables.map { textWidth($0, lyricSize, bold: false) }.max() ?? 0
        if syllables == 0, let id = cell.chord, let name = chord(id) {
            return textWidth(name, chordSize, bold: true) + 8
        }
        return max(syllables, textWidth(" ", lyricSize, bold: false))
    }

    private func textWidth(_ text: String, _ size: CGFloat, bold: Bool) -> CGFloat {
        let font: UIFont = bold
            ? UIFont.systemFont(ofSize: size, weight: .bold).withDesign(.rounded)
            : UIFont.systemFont(ofSize: size)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func cellView(_ cell: ScoreChart.Cell, verses: Int) -> some View {
        let name = cell.chord.flatMap(chord)
        let wordless = cell.syllables.allSatisfy(\.isEmpty)
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
                let syllable = verse < cell.syllables.count ? cell.syllables[verse] : ""
                Text(syllable.isEmpty ? " " : syllable)
                    .font(.system(size: verse == 0 ? lyricSize : lyricSize * 0.92))
                    .foregroundStyle(.white.opacity(verse == 0 ? 0.95 : 0.72))
                    .fixedSize()
                    .frame(height: lyricSize * 1.25, alignment: .leading)
            }
        }
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
