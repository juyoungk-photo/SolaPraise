//
//  ChipFlow.swift
//  SolaPraise
//
//  Chips that wrap instead of running off the edge.
//
//  On a phone a single row fits about three and a half of them, so a team of
//  nine was mostly off screen behind a scroll nobody thinks to try. Wrapping
//  costs one more line and shows everyone — and "who is on this week" is the
//  question the row exists to answer.
//
//  iPad keeps the single scrolling row, where the chips sit beside the
//  service and every row staying the same height is what makes the month
//  scannable.
//

import SwiftUI

struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth,
                      height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
