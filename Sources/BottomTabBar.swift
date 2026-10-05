//
//  BottomTabBar.swift
//  SolaPraise
//
//  The iPad's tab bar, at the bottom, drawn by us.
//
//  WHY THIS EXISTS: iPadOS 26 puts a TabView's bar at the top of the screen,
//  in the middle, where it is both a long reach and easy to miss — the
//  opposite of a thumb's resting place when the iPad is on a music stand.
//  `UIDesignRequiresCompatibility` used to restore the classic bottom bar and
//  is still set in Info.plist, but 26.4 no longer honours it for tab
//  placement (verified on the simulator: the flag is present in the built
//  app and the bar is still at the top). There is no API to ask for the
//  bottom, so the bar is ours.
//
//  The look is iPadOS 26's own: a floating capsule with the selected tab in
//  a raised pill of its own. That part of the new design was the good part —
//  it was only the placement that put it out of reach. Keeping the look and
//  moving it down is not a compromise between the two, it is both.
//
//  iPhone is left alone. Its system bar is already at the bottom, already
//  correct, and reimplementing it would only add a way to get it wrong.
//

import SwiftUI

enum AppLayout {

    /// Only the iPad draws its own bar — see the note above.
    static var usesCustomTabBar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// The margin a floating bar keeps from the screen edge. Zero on iPhone,
    /// where the docked player is a full-width bar sitting on a full-width
    /// tab bar and an inset would only break that line.
    static var floatingInset: CGFloat { usesCustomTabBar ? 16 : 0 }

    /// The gap between the docked player and the tab bar, so the two read as
    /// two floating things rather than one shape with a crease.
    static var floatingGap: CGFloat { usesCustomTabBar ? 8 : 0 }

    /// What the floating bar occupies, including the gap beneath it. Content
    /// is inset by exactly this, so the last row clears the bar instead of
    /// hiding behind it.
    static let tabBarHeight: CGFloat = 60
}

struct TabItem: Identifiable {
    let tag: ContentView.Tab
    let title: String
    let symbol: String

    var id: ContentView.Tab { tag }
}

struct BottomTabBar: View {
    @Binding var selection: ContentView.Tab
    let items: [TabItem]

    /// Lets the selected pill slide between tabs rather than blink from one
    /// to the next — the movement is what shows the two are the same thing.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item.tag }
                } label: {
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selection == item.tag
                                         ? Color.accentColor
                                         : Color.primary.opacity(0.7))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background {
                            if selection == item.tag {
                                Capsule()
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.10),
                                            radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "selected", in: pill)
                            }
                        }
                        // The whole pill is the target, not the glyph-sized
                        // text inside it.
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == item.tag
                                        ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .padding(.bottom, 6)
    }
}
