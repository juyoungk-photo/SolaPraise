//
//  Toast.swift
//  SolaPraise
//
//  A small bubble that says an action worked, then goes away.
//
//  WHY: 콘티에 추가 used to finish in silence. The write goes to a sheet
//  over the network, nothing on the playing screen changes, and a person
//  with no sign it had worked did the reasonable thing and added it again —
//  one 콘티 ended up with the same video seven times. An action whose result
//  is somewhere else on the screen, or nowhere on it, needs to say so where
//  the person is looking.
//
//  At the top of the window, over everything including the player, and
//  never in the way: it takes no touches and leaves on its own.
//

import SwiftUI

@MainActor
final class Toast: ObservableObject {

    static let shared = Toast()

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
        let tint: Color
    }

    @Published private(set) var current: Message?

    func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        let message = Message(text: text, symbol: symbol, tint: tint)
        withAnimation(.spring(duration: 0.3)) { current = message }
        Task {
            // Long enough to read a short sentence twice.
            try? await Task.sleep(for: .seconds(2.4))
            // Only the bubble this call put up; a newer one keeps its time.
            guard current?.id == message.id else { return }
            withAnimation(.easeOut(duration: 0.25)) { current = nil }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject private var toast = Toast.shared

    var body: some View {
        VStack {
            if let message = toast.current {
                HStack(spacing: 8) {
                    Image(systemName: message.symbol)
                        .foregroundStyle(message.tint)
                    Text(message.text)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .padding(.horizontal, 24)
                // Below the navigation bar rather than over it: on top of
                // the bar's own buttons the bubble read as part of them.
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
