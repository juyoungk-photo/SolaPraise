//
//  ScoreChartView.swift
//  SolaPraise
//
//  The stand's 코드표: a score read as rows of bars, each chord set over the
//  syllables it falls on, in the key the stand is showing.
//
//  Same feature on both devices; only the row length differs — eight bars
//  across an iPad, four on a phone, so a chord stays large enough to read
//  at arm's length either way.
//

import SwiftUI

struct ScoreChartView: View {
    let systems: [ScoreChart.System]
    /// The chord as it should read now — transposed, spelled — by id; nil
    /// for a chord the reader has since removed.
    let chord: (UUID) -> String?
    let scale: CGFloat

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Eight bars across an iPad, four on a phone — half that under several
    /// verses, where each bar holds a column of lines.
    private func barsPerRow(verses: Int) -> Int {
        (sizeClass == .regular ? 8 : 4) / (verses > 1 ? 2 : 1)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(Array(systems.enumerated()), id: \.offset) { _, system in
                    let perRow = barsPerRow(verses: system.verses)
                    let rows = stride(from: 0, to: system.bars.count, by: perRow).map {
                        Array(system.bars[$0..<min($0 + perRow, system.bars.count)])
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, bars in
                            row(bars, verses: system.verses)
                        }
                    }
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

    /// One row of bars, equal widths, a line between each — the way a
    /// chord chart is printed.
    private func row(_ bars: [ScoreChart.Bar], verses: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                HStack(alignment: .top, spacing: 0) {
                    barLine(repeatStart: bar.repeatStart)
                    cell(bar, verses: verses)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if bar.repeatEnd { repeatEnd }
                }
            }
            // The row's closing barline.
            Rectangle().fill(.white.opacity(0.35)).frame(width: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ bar: ScoreChart.Bar, verses: Int) -> some View {
        // A flow, not a row: in a phone's narrow bar, three chords side by
        // side squeezed their words into one-syllable columns.
        SegmentFlow(spacing: 8, lineSpacing: 6) {
            if bar.segments.allSatisfy({ $0.chord == nil }) && bar.segments.allSatisfy({ $0.lyrics.allSatisfy(\.isEmpty) }) {
                // No chord and no words: the chord before carries on.
                Text("·")
                    .font(.system(size: 22 * scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 3) {
                    Text(segment.chord.flatMap(chord) ?? " ")
                        .font(.system(size: 21 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    ForEach(0..<max(verses, segment.lyrics.count), id: \.self) { verse in
                        let words = verse < segment.lyrics.count ? segment.lyrics[verse] : ""
                        Text(words.isEmpty ? " " : words)
                            .font(.system(size: 16 * min(scale, 1.4)))
                            .foregroundStyle(.white.opacity(verse == 0 ? 0.92 : 0.7))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Lays its items out left to right at their natural width, starting a
    /// new line when the next does not fit; an item wider than the whole
    /// bar is given the bar's width and wraps inside it.
    private struct SegmentFlow: Layout {
        var spacing: CGFloat
        var lineSpacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? .infinity
            return arrange(subviews, width: width).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let placed = arrange(subviews, width: bounds.width)
            for (index, frame) in placed.frames.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                      proposal: ProposedViewSize(width: frame.width, height: frame.height))
            }
        }

        private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
            var frames: [CGRect] = []
            var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
            for subview in subviews {
                var size = subview.sizeThatFits(.unspecified)
                if size.width > width {
                    size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                    size.width = min(size.width, width)
                }
                if x > 0, x + size.width > width {
                    x = 0
                    y += lineHeight + lineSpacing
                    lineHeight = 0
                }
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                x += size.width + spacing
                lineHeight = max(lineHeight, size.height)
                widest = max(widest, x - spacing)
            }
            return (frames, CGSize(width: min(widest, width), height: y + lineHeight))
        }
    }

    private func barLine(repeatStart: Bool) -> some View {
        HStack(spacing: 2) {
            Rectangle().fill(.white.opacity(repeatStart ? 0.8 : 0.35)).frame(width: repeatStart ? 3 : 1)
            if repeatStart { repeatDots }
        }
    }

    private var repeatEnd: some View {
        HStack(spacing: 2) {
            repeatDots
            Rectangle().fill(.white.opacity(0.8)).frame(width: 3)
        }
    }

    private var repeatDots: some View {
        VStack(spacing: 6) {
            Circle().frame(width: 4, height: 4)
            Circle().frame(width: 4, height: 4)
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding(.top, 10)
    }
}
