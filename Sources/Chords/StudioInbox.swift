//
//  StudioInbox.swift
//  SolaPraise
//
//  One file, handed from wherever it was found to 작업실.
//
//  음원 찾기 can be opened from four places — the 찬양 grid, the player, a
//  queue row, a 악보 — and none of them is 작업실. Without somewhere to put
//  the file, buying it ended with "now go to the other tab and find it
//  again", which is the step people do not take.
//
//  So the picked file is left here, 작업실 is selected, and it starts the
//  analysis the moment it appears. One slot, not a queue: the analyser runs
//  one song at a time, and a second pick before the first is collected means
//  the second is the one that was meant.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class StudioInbox {
    static let shared = StudioInbox()

    struct Item: Equatable {
        let url: URL
        let title: String
    }

    /// Set by whoever picked the file, cleared by 작업실 when it takes it.
    private(set) var pending: Item?

    /// Raised so ContentView can switch tabs without 음원 찾기 having to know
    /// what a tab is.
    var wantsStudio = false

    private init() {}

    func submit(url: URL, title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = Item(
            url: url,
            title: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
        )
        wantsStudio = true
    }

    /// Hands the file over exactly once.
    func take() -> Item? {
        defer { pending = nil }
        return pending
    }
}
