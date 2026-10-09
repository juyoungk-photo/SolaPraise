//
//  DevGate.swift
//  SolaPraise
//
//  Which accounts see a feature that is not finished yet.
//
//  Right now that is the chord analysis. It works, but not well enough to
//  put in front of a worship team: a chart with the wrong chords is worse
//  than no chart, because somebody will play it on Sunday. So it stays
//  visible to the person developing it and invisible to everyone else, in
//  the same build, rather than living on a branch that drifts.
//
//  THE ADDRESSES ARE NOT IN THIS FILE. The repository is public, and the
//  history was scrubbed once already to get a personal handle and a church
//  domain out of it. They are read from the gitignored Secrets.xcconfig,
//  the same way the API keys are — a build without that file simply has no
//  developer accounts, which is the right answer for every build but one.
//
//  NOT A SECURITY BOUNDARY, and not pretending to be. Anyone can read this
//  source and see what it gates; the point is to keep an unfinished feature
//  out of a teammate's way, not to defend it.
//

import Foundation

enum DevGate {

    /// Whether this account sees in-development features.
    ///
    /// Both addresses are checked, because the account that plays YouTube
    /// and the one that writes the team sheet are often different and the
    /// developer may be signed in under either.
    @MainActor
    static func isUnlocked(auth: GoogleAuthManager, planning: PlanningAuth) -> Bool {
        let allowed = AppSecrets.devAccounts
        guard !allowed.isEmpty else { return false }
        return [auth.email, planning.email]
            .compactMap { $0 }
            .contains { matches($0, allowed) }
    }

    /// Matches the whole address or just its local part, so a config may say
    /// either "someone@example.org" or "someone".
    private static func matches(_ email: String, _ allowed: Set<String>) -> Bool {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !address.isEmpty else { return false }
        if allowed.contains(address) { return true }
        let local = address.split(separator: "@").first.map(String.init) ?? address
        return allowed.contains(local)
    }
}
