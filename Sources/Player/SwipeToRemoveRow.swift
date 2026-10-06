//
//  SwipeToRemoveRow.swift
//  SolaPraise
//
//  Swipe-to-delete for a row that is not in a List.
//
//  WHY THIS EXISTS: `.swipeActions` is a List feature. The player's 재생목록
//  is a VStack inside the page that scrolls under the video — it cannot be a
//  List without the whole screen becoming one — so the rows there had no
//  swipe at all, in either direction. Pulling one sideways did nothing, which
//  reads as the queue not being editable rather than as the gesture being
//  unavailable.
//
//  Either direction reveals the button. Which way a list "opens" is a habit
//  rather than a rule, and a swipe that answers only one of the two guesses
//  is a swipe half the people will conclude is missing.
//
//  Never a full swipe: the button has to be tapped. Removing a song mid
//  service by brushing the screen is not a mistake worth allowing.
//

import SwiftUI

struct SwipeToRemoveRow<Content: View>: View {
    let onRemove: () -> Void
    /// What the revealed button shows. Removing from a queue is a deletion;
    /// unpinning is not, so it should not wear a red bin.
    var symbol: String = "trash"
    var tint: Color = .red
    var accessibility: String = "삭제"
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0

    private static var revealWidth: CGFloat { 84 }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // The button sits on the side the row has moved away from.
                if offset > 0 { button; Spacer(minLength: 0) }
                else { Spacer(minLength: 0); button }
            }

            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { value in
                            // Vertical wins, so the page can still scroll
                            // with a finger that starts on a row.
                            guard abs(value.translation.width)
                                    > abs(value.translation.height) else { return }
                            offset = max(-Self.revealWidth,
                                         min(Self.revealWidth, value.translation.width))
                        }
                        .onEnded { value in
                            let travelled = value.translation.width
                            withAnimation(.snappy(duration: 0.2)) {
                                guard abs(travelled) > Self.revealWidth * 0.55 else {
                                    offset = 0
                                    return
                                }
                                offset = travelled > 0 ? Self.revealWidth : -Self.revealWidth
                            }
                        }
                )
        }
        .clipped()
        // Closing by tapping elsewhere is what people try first.
        .onTapGesture {
            if offset != 0 { withAnimation(.snappy(duration: 0.2)) { offset = 0 } }
        }
    }

    private var button: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { offset = 0 }
            onRemove()
        } label: {
            Label(accessibility, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: Self.revealWidth)
                .frame(maxHeight: .infinity)
                .background(tint)
        }
        .buttonStyle(.plain)
        .opacity(offset == 0 ? 0 : 1)
        .accessibilityLabel(accessibility)
    }
}
