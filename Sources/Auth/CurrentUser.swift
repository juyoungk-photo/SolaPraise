//
//  CurrentUser.swift
//  SolaPraise
//
//  Google-backed identity façade. Ported from PraiseTheLord.
//  Views ask this rather than reaching into GoogleAuthManager directly.
//

import Foundation

@MainActor
struct CurrentUser {
    let email: String?
    let displayName: String?
    let avatarURL: URL?

    init(auth: GoogleAuthManager) {
        self.email = auth.email
        self.displayName = auth.displayName
        self.avatarURL = auth.avatarURL
    }

    /// Best available human-readable label, falling back sensibly.
    var label: String {
        displayName ?? email ?? "Signed in"
    }
}
