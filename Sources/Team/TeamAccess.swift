//
//  TeamAccess.swift
//  SolaPraise
//
//  Whether the 예배 준비 tab appears.
//
//  WHAT THIS IS: the signed-in address is checked against the Members tab of
//  the team sheet, and the tab appears when it matches. That keeps a screen
//  about role assignments and rehearsal notes out of the way of someone who
//  only came to listen.
//
//  WHAT THIS IS NOT: security. A client-side email check is a courtesy — it
//  decides what to SHOW, not what can be READ. What actually protects the
//  team's information is Google's own sharing on the sheet: a person the
//  leader has not shared it with gets 403 from the API and an empty screen,
//  whatever this file concludes. Treating the check as a lock would be
//  believing a locked door with the wall missing beside it.
//

import Foundation

enum TeamAccess {

    enum State: Equatable {
        /// No sheet configured — nobody has set the team up yet.
        case unconfigured
        /// A sheet exists but nobody is signed in, so there is no address to
        /// match and no token to read it with.
        case signInRequired
        /// Signed in, but not on the roster.
        case notAMember(email: String)
        case member(email: String, name: String)

        var isMember: Bool {
            if case .member = self { return true }
            return false
        }
    }

    static func evaluate(
        sheetId: String?,
        email: String?,
        displayName: String?,
        roster: Set<String>
    ) -> State {
        guard let sheetId, !sheetId.isEmpty else { return .unconfigured }
        _ = sheetId
        guard let email, !email.isEmpty else { return .signInRequired }

        // An empty roster means the sheet has no Members tab. Fall through to
        // membership rather than locking everyone out: whoever can read the
        // sheet at all was given access deliberately, and that is the real
        // gate.
        guard !roster.isEmpty else {
            return .member(email: email, name: displayName ?? email)
        }
        guard roster.contains(email.lowercased()) else {
            return .notAMember(email: email)
        }
        return .member(email: email, name: displayName ?? email)
    }

    /// Pulls the id out of a pasted Sheets URL, or accepts a bare id.
    static func sheetId(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("/"), !trimmed.contains(" ") { return trimmed }
        // .../spreadsheets/d/<id>/edit
        guard let range = trimmed.range(
            of: "/spreadsheets/d/([A-Za-z0-9_-]+)",
            options: .regularExpression
        ) else { return nil }
        return trimmed[range]
            .replacingOccurrences(of: "/spreadsheets/d/", with: "")
    }
}
