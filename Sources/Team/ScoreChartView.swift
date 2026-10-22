//
//  ScoreChartView.swift
//  SolaPraise
//
//  코드표: the chart read as a chord sheet, laid out as ChordPro lays a
//  song out (ChordProSheet) — each verse whole, its chords over its own
//  words, the chorus once and named after it, an intro as chords alone.
//
//  WHY: the 코드표 was a hymnal — every verse stacked under one chord line,
//  note by note, syllables spaced into columns with dashes between. A band
//  reading it mid-song had to find their verse's row in every line, and
//  read words broken into syllables. ChordPro is how chord sheets are read
//  everywhere else: a verse is a paragraph of words, a chord sits over the
//  syllable it is played on, and a line breaks only between words.
//
//  What stays from the score: the words as Korean is written (LyricSpacing),
//  repeats (𝄆 𝄇), and 가사 고치기 on a line, which corrects the staff it
//  was read from.
//
//  Same on both devices; a phone wraps the line sooner.
//

import SwiftUI
import UIKit

struct ScoreChartView: View {
    let song: ChordProSheet.Song
    let scale: CGFloat
    /// How much room the words get, apart from their size: 1 as first
    /// drawn, more to space words and lines further apart.
    var spacing: CGFloat = 1
    /// 가사 고치기 for a staff, by its index; nil where it cannot be edited.
    var onEditLine: ((Int) -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Larger on an iPad, which stands further away and has the width.
    private var deviceScale: CGFloat { sizeClass == .regular ? 1.4 : 1 }
    private var chordFont: Font { .system(size: 19 * scale * deviceScale, weight: .bold, design: .rounded) }
    /// A little under the chords: Hangul at the same size reads larger
    /// than a Latin capital.
    private var lyricFont: Font { .system(size: 18 * scale * deviceScale) }
    private var labelFont: Font { .system(size: 13 * scale * deviceScale, weight: .semibold) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22 * spacing) {
                if let key = song.key {
                    Text("Key \(key)")
                        .font(labelFont)
                        .foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(song.sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }
                Text(onEditLine == nil
                     ? "악보에서 읽은 코드와 가사입니다. 틀린 글자가 있을 수 있으니 악보와 함께 확인하세요."
                     : "악보에서 읽은 코드와 가사입니다. 틀린 글자는 그 줄을 길게 눌러 고치세요.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: ChordProSheet.Section) -> some View {
        switch section.kind {
        case .chorusAgain:
            // Named, not written out again — as ChordPro's {chorus}.
            Label(section.label ?? "후렴", systemImage: "arrow.uturn.left")
                .font(labelFont)
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
        default:
            VStack(alignment: .leading, spacing: 12 * spacing) {
                if let label = section.label {
                    Text(label)
                        .font(labelFont)
                        .foregroundStyle(.white.opacity(0.55))
                }
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            // The chorus set off by a bar down its side, as ChordPro prints it.
            .padding(.leading, section.kind == .chorus ? 14 : 0)
            .overlay(alignment: .leading) {
                if section.kind == .chorus {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                }
            }
        }
    }

    // MARK: - Lines

    private func lineView(_ line: ChordProSheet.Line) -> some View {
        let chorded = line.words.contains { $0.pieces.contains { $0.chord != nil } }
        let last = line.words.count - 1
        return WordFlow(spacing: wordGap, lineSpacing: 6 * spacing) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                // The repeat marks ride on the first and last words, so a
                // mark never wraps onto a row of its own.
                HStack(alignment: .bottom, spacing: 4) {
                    if index == 0, line.repeatStart { marker("𝄆", chorded: chorded) }
                    wordView(word, chorded: chorded, instrumental: line.isInstrumental)
                    if index == last, line.repeatEnd { marker("𝄇", chorded: chorded) }
                }
            }
        }
        .contentShape(Rectangle())
        // Long-pressed, as text is everywhere else on iOS.
        .contextMenu {
            if let onEditLine, !line.isInstrumental {
                Button { onEditLine(line.system) } label: {
                    Label("이 줄 가사 고치기", systemImage: "pencil")
                }
            }
        }
    }

    /// A word: each piece its chord over its syllables, the chord row left
    /// out of a line that has none.
    private func wordView(_ word: ChordProSheet.Word, chorded: Bool, instrumental: Bool) -> some View {
        let lastPiece = word.pieces.count - 1
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(word.pieces.enumerated()), id: \.offset) { index, piece in
                VStack(alignment: .leading, spacing: 1) {
                    if chorded {
                        Text(piece.chord ?? " ")
                            .font(chordFont)
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                            .frame(height: chordHeight, alignment: .bottomLeading)
                    }
                    if !instrumental {
                        Text(piece.text.isEmpty ? " " : piece.text)
                            .font(lyricFont)
                            .foregroundStyle(.white)
                            .fixedSize()
                    }
                }
                // As wide as its syllables — or its chord, where that is
                // wider: a chord over the last syllable of a word may reach
                // into the gap before the next word, as ChordPro sheets
                // print it, rather than pushing the word apart.
                .frame(width: pieceWidth(piece, lastInWord: index == lastPiece, instrumental: instrumental),
                       alignment: .leading)
            }
        }
    }

    private var wordGap: CGFloat { 9 * scale * deviceScale * spacing }
    private var chordSize: CGFloat { 19 * scale * deviceScale }
    private var lyricSize: CGFloat { 18 * scale * deviceScale }
    private var chordHeight: CGFloat { chordSize * 1.25 }

    private func pieceWidth(_ piece: ChordProSheet.Piece, lastInWord: Bool, instrumental: Bool) -> CGFloat {
        let words = instrumental ? 0 : Self.width(piece.text, UIFont.systemFont(ofSize: lyricSize))
        guard let chord = piece.chord else { return words }
        let rounded = UIFont.systemFont(ofSize: chordSize, weight: .bold)
            .fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: chordSize) }
            ?? UIFont.systemFont(ofSize: chordSize, weight: .bold)
        // Clear of the next chord by a little.
        let needed = Self.width(chord, rounded) + 6
        return max(words, lastInWord ? needed - wordGap : needed)
    }

    private static func width(_ text: String, _ font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func marker(_ symbol: String, chorded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if chorded { Text(" ").font(chordFont) }
            Text(symbol).font(lyricFont).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Words left to right, a new row when the next does not fit: a line
    /// breaks only between words.
    private struct WordFlow: Layout {
        var spacing: CGFloat
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
                x += size.width + spacing
                lineHeight = max(lineHeight, size.height)
                widest = max(widest, x - spacing)
            }
            return (origins, CGSize(width: min(widest, width), height: y + lineHeight))
        }
    }
}
