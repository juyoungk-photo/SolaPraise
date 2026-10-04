//
//  HomeCardView.swift
//  SolaPraise
//
//  One home tile. Wide cards (시편, 검색) span both columns; channel and
//  playlist cards sit two-up.
//

import SwiftUI

struct HomeCardView: View {
    let card: HomeCard
    let subtitle: String?
    let thumbnailURL: URL?
    let isRead: Bool
    /// When set, the card grows a −/+ pair. Nil for cards that have nothing to
    /// step through, which is most of them.
    var onStep: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A grid card always gets a header, image or not. A row in the
            // grid is as tall as its tallest card, so a card with no
            // thumbnail next to one with a thumbnail was stretched into a
            // tall empty box — which is what 시편 듣기 and a freshly added
            // 재생목록 looked like before their artwork arrived. The
            // placeholder fills that space with the card's own symbol.
            // Wide cards span the row alone, so they size to their text.
            if thumbnailURL != nil || !card.kind.isWide {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let thumbnailURL {
                            AsyncImage(url: thumbnailURL) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFill()
                                default: placeholderArtwork
                                }
                            }
                        } else {
                            placeholderArtwork
                        }
                    }
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: card.kind.symbolName)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isRead {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if let onStep {
                        Spacer(minLength: 8)
                        // Buttons, not a Stepper: the whole card is a tap
                        // target, and a Stepper inside it swallows the tap.
                        HStack(spacing: 6) {
                            stepButton("minus", onStep: onStep, delta: -1)
                            stepButton("plus", onStep: onStep, delta: 1)
                        }
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(minHeight: card.kind.isWide ? 0 : 132, alignment: .top)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Stands in for missing artwork: the card's own symbol on a tinted wash,
    /// so an imageless card still reads as a card rather than a blank panel.
    private var placeholderArtwork: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.25),
                                Color.accentColor.opacity(0.08)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: card.kind.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint.opacity(0.8))
            }
    }

    private func stepButton(_ symbol: String,
                            onStep: @escaping (Int) -> Void,
                            delta: Int) -> some View {
        Button { onStep(delta) } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}
