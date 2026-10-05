//
//  AudioSourceMenu.swift
//  SolaPraise
//
//  음원 찾기, shared wherever a song is named.
//

import SwiftUI

/// Kept as a button that opens 음원 찾기, so the four places that showed a
/// menu of search links now show the search itself.
struct AudioSourceMenu<Label: View>: View {
    let title: String
    @ViewBuilder var label: Label

    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            label
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            AudioSourceSheet(title: title)
        }
    }
}
