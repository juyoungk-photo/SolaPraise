//
//  SongMapView.swift
//  SolaPraise
//
//  곡의 흐름 — the shape of a song on one line.
//
//  WHY: the structure was already being detected, but it was only ever shown
//  as a vertical list of sections. A list tells you a song has six parts; it
//  does not tell you that parts 2, 4 and 6 are the same chorus, that the
//  bridge is half the length of a verse, or that the song never returns to
//  where it started. That is the part a team actually talks about in
//  rehearsal — "we go round the chorus twice, then the bridge" — and it was
//  the part the app made you reconstruct in your head.
//
//  Sections that share a chord progression share a colour, so repetition is
//  visible before a single word is read. Width is proportional to the number
//  of chords rather than to wall-clock seconds: chord count is exactly known,
//  tracks bars rather than tempo, and does not distort when detection drops a
//  moment of silence.
//

import SwiftUI

struct SongMapView: View {
    let sections: [SongSection]
    /// How much the detection is worth trusting. Shown when it is not much:
    /// a map that presents six guesses as structure is worse than no map,
    /// because it looks like an answer.
    var quality: StructureQuality? = nil
    /// Tapping a block jumps the sheet to that section.
    var onSelect: (SongSection) -> Void = { _ in }

    private let spacing: CGFloat = 3
    private let barHeight: CGFloat = 46

    var body: some View {
        if sections.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 7) {
                header
                bar
                if let line = repeatSummary {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                qualityNote
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("곡의 흐름")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("^[\(sections.count) 섹션](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The bar

    private var bar: some View {
        GeometryReader { proxy in
            let widths = blockWidths(in: proxy.size.width)
            HStack(spacing: spacing) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    block(section, width: widths[index])
                }
            }
        }
        .frame(height: barHeight)
    }

    private func block(_ section: SongSection, width: CGFloat) -> some View {
        let tint = Self.colour(for: section.patternKey)
        return Button {
            onSelect(section)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
                // Below ~52pt a name cannot be read, so the pattern letter
                // stands in — it still says "this is the same part as that
                // one", which is the whole point of the row.
                Text(width >= 52 ? section.label : section.patternKey)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 4)
            }
            .frame(width: width, height: barHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.label), 코드 \(section.chordCount)개")
        .accessibilityHint("이 섹션으로 이동")
    }

    // MARK: - Widths

    /// Proportional to chord count, but never narrower than a thumb.
    ///
    /// A two-chord 간주 next to a thirty-two-chord verse would otherwise be a
    /// hairline nobody can hit. Short blocks are raised to a floor and the
    /// space is taken back from the blocks that have room to give, so the row
    /// still fills the width exactly.
    private func blockWidths(in total: CGFloat) -> [CGFloat] {
        let gaps = CGFloat(max(0, sections.count - 1)) * spacing
        let usable = max(0, total - gaps)
        let even = usable / CGFloat(max(1, sections.count))
        let floorWidth: CGFloat = 30

        guard usable > 0 else { return sections.map { _ in 0 } }
        // Not enough room to honour the floor for everyone — split evenly.
        guard even >= floorWidth else { return sections.map { _ in even } }

        let counts = sections.map { CGFloat(max(1, $0.chordCount)) }
        let sum = counts.reduce(0, +)
        guard sum > 0 else { return sections.map { _ in even } }

        var widths = counts.map { usable * $0 / sum }
        let deficit = widths.reduce(0) { $0 + max(0, floorWidth - $1) }
        guard deficit > 0 else { return widths }

        let surplus = widths.reduce(0) { $0 + max(0, $1 - floorWidth) }
        guard surplus > deficit else { return sections.map { _ in even } }

        widths = widths.map { w in
            w < floorWidth ? floorWidth : w - (w - floorWidth) * deficit / surplus
        }
        return widths
    }

    // MARK: - Summary

    /// "후렴 3번 반복" — but only when the repeated group goes by one name.
    ///
    /// 절 1 and 절 2 normally share a progression, so they share a colour
    /// while carrying different labels. Picking either name for the pair
    /// would be wrong, so a mixed group gets the legend without the count.
    private var repeatSummary: String? {
        let legend = "같은 색은 같은 코드 진행입니다"
        var groups: [String: [SongSection]] = [:]
        for section in sections { groups[section.patternKey, default: []].append(section) }

        let repeated = groups.filter { $0.value.count > 1 }
        guard !repeated.isEmpty else { return nil }

        // Prefer a group that can actually be named; then the one that
        // repeats most; then the one that comes first, so the line is stable.
        let named = repeated.values.filter { group in
            group.dropFirst().allSatisfy { $0.label == group[0].label }
        }
        guard let best = named.max(by: { a, b in
            a.count != b.count ? a.count < b.count : a[0].startIndex > b[0].startIndex
        }) else { return legend }

        return "\(legend) · \(best[0].label) \(best.count)번 반복"
    }

    // MARK: - How much to trust it

    /// What went wrong with the input, in the words of the thing to do about
    /// it. Detection is a guess; this is the map admitting when the guess
    /// was made from very little.
    @ViewBuilder
    private var qualityNote: some View {
        if let quality, !quality.findings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(quality.findings, id: \.rawValue) { finding in
                    Label(finding.message, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if quality.noiseShare > 0.3 {
                    Text("코드 \(quality.rawEvents)개 중 \(quality.dropped)개는 순간적인 흔들림으로 보고 제외했습니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Colour

    /// Keyed by the pattern letter, so the same progression is the same
    /// colour everywhere it appears — in the bar and in the section headers.
    static func colour(for patternKey: String) -> Color {
        guard let scalar = patternKey.unicodeScalars.first else { return palette[0] }
        let index = Int(scalar.value) - Int(UnicodeScalar("A").value)
        guard index >= 0 else { return palette[0] }
        return palette[index % palette.count]
    }

    /// Mid-tone on purpose: white text has to stay legible on every one of
    /// them, in light mode and dark.
    private static let palette: [Color] = [
        Color(red: 0.80, green: 0.57, blue: 0.20),   // gold — the app's own
        Color(red: 0.32, green: 0.52, blue: 0.69),   // slate blue
        Color(red: 0.42, green: 0.60, blue: 0.42),   // sage
        Color(red: 0.69, green: 0.42, blue: 0.45),   // dusty rose
        Color(red: 0.50, green: 0.45, blue: 0.67),   // muted violet
        Color(red: 0.40, green: 0.56, blue: 0.58)    // teal
    ]
}
