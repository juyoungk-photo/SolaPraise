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
//  iPhone is left alone. Its system bar is already at the bottom, already
//  correct, and reimplementing it would only add a way to get it wrong.
//

import SwiftUI

enum AppLayout {

    /// Only the iPad draws its own bar — see the note above.
    static var usesCustomTabBar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Matches UIKit's compact tab bar, so the reach is what a hand expects.
    static let tabBarHeight: CGFloat = 56
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    selection = item.tag
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: .regular))
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: AppLayout.tabBarHeight)
                    // The whole column is the target, not just the glyph.
                    .contentShape(Rectangle())
                    .foregroundStyle(selection == item.tag
                                     ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == item.tag
                                        ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: AppLayout.tabBarHeight)
        // The material runs on down behind the home indicator; the buttons
        // stay above it, inside the safe area where they can be hit.
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { Divider() }
    }
}
