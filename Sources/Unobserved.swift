//
//  Unobserved.swift
//  SolaPraise
//
//  The player and the quota ledger for views that only act on them — tell
//  the player to play, build an API client — and never draw their state.
//  Read from here they are a plain reference; as @EnvironmentObject every
//  change to them redraws the view that holds them.
//
//  WHY: 예배 준비, 찬양, 홈 and 말씀 observed the player only to call
//  play(). One tap on ▶ publishes the queue, the index and the mode, so it
//  redrew all four tab screens — the whole schedule, a grid of a hundred
//  videos — several times over, in the frames the player was opening in.
//  The quota ledger publishes on every API call, so a feed refresh redrew
//  the same screens once per channel fetched. A view that shows the state
//  observes it, in a view of its own the size of what it shows
//  (QuotaCount).
//
//  Injected once at the root (SolaPraiseApp); sheets inherit it.
//

import SwiftUI

private struct PlayerActionsKey: EnvironmentKey {
    static let defaultValue: PlayerHost? = nil
}

private struct QuotaLedgerKey: EnvironmentKey {
    static let defaultValue: QuotaLedger? = nil
}

extension EnvironmentValues {
    /// The player, to act on. Observe `PlayerHost` only to draw its state.
    var playerActions: PlayerHost! {
        get { self[PlayerActionsKey.self] }
        set { self[PlayerActionsKey.self] = newValue }
    }

    /// The quota ledger, to build clients with. Observe it only to show
    /// what is left.
    var quotaLedger: QuotaLedger! {
        get { self[QuotaLedgerKey.self] }
        set { self[QuotaLedgerKey.self] = newValue }
    }
}

/// Searches left today, observing the ledger by itself — so a count in a
/// toolbar does not redraw the screen it sits on.
struct QuotaCount<Content: View>: View {
    @EnvironmentObject private var quota: QuotaLedger
    @ViewBuilder let content: (QuotaLedger) -> Content

    var body: some View { content(quota) }
}
