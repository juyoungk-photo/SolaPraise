//
//  AccountTag.swift
//  SolaPraise
//
//  Which account a feature is acting as, said where the feature is.
//
//  WHY: most of the app needs no account — the feeds, playback, search,
//  the 콘티 folder and attached charts all work signed out — and the two
//  that do use DIFFERENT accounts: YouTube playlists the main sign-in,
//  예배 준비 the church account when one is connected. A person with three
//  Google accounts could not tell from the screen whose playlists they
//  were editing, or as whom a sheet was being written. Each place that
//  uses an account now names it.
//

import SwiftUI

struct AccountTag: View {
    enum Use {
        /// YouTube playlists: the main sign-in.
        case youtube
        /// 예배 준비: the church account when connected, else the main one.
        case team
    }

    let use: Use

    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: use == .youtube ? "play.rectangle" : "person.2")
                .font(.caption2)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch use {
        case .youtube:
            return auth.email.map { "YouTube 계정 \($0)" } ?? "YouTube 계정 로그인 안 됨"
        case .team:
            return team.actingEmail(auth: auth, planning: planning).map {
                planning.isSignedIn ? "교회 계정 \($0)" : "계정 \($0)"
            } ?? "로그인 안 됨"
        }
    }
}
