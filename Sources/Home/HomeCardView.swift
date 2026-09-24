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
            if let thumbnailURL {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: thumbnailURL) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: Rectangle().fill(.quaternary)
                            }
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
