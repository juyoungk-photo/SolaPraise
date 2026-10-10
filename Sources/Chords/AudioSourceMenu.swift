//
//  AudioSourceMenu.swift
//  SolaPraise
//
//  음원 찾기, shared wherever a song is named.
//

import SwiftUI

/// Kept as a button that opens 음원 찾기, so the four places that showed a
/// menu of search links now show the search itself.
///
/// In development only, for now — behind DevGate with 작업실, whose input
/// it is. Decided here, once, so every place that offers it (player, queue,
/// 찬양 grid, 악보) hides it together on both devices.
struct AudioSourceMenu<Label: View>: View {
    let title: String
    var seconds: Int?
    var artist: String?
    @ViewBuilder var label: Label

    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @State private var showSheet = false

    var body: some View {
        if DevGate.isUnlocked(auth: auth, planning: planning) { button }
    }

    private var button: some View {
        Button {
            showSheet = true
        } label: {
            label
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            AudioSourceSheet(title: title, seconds: seconds, artist: artist)
        }
    }
}
