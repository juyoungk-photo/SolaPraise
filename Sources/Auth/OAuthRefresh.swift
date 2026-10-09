//
//  OAuthRefresh.swift
//  SolaPraise
//
//  Telling a dead sign-in from a bad moment.
//
//  WHY THIS EXISTS: the church-account grant treated EVERY failed token
//  refresh as a revoked one — a timeout on a train, a dropped Wi-Fi, a
//  Google 503 — and signed out, deleting the refresh token from the
//  Keychain. A moment offline then meant signing in to the church account
//  again, and anything that refreshed in the background did it silently.
//
//  Google says a grant is gone in exactly one way: HTTP 400 or 401 with
//  `invalid_grant` (revoked, expired, or a Testing-mode token past its
//  seven days) or `unauthorized_client` / `invalid_client` (the client
//  itself was changed). Everything else is worth trying again later.
//
//  Pure Foundation, so it is checked directly: Tools/check-oauth-refresh.swift.
//

import Foundation

enum OAuthRefresh {

    enum Outcome: Equatable {
        /// The grant is gone. Sign out; only a new sign-in will help.
        case revoked
        /// Anything else — network, server, rate limit. Keep the grant.
        case transient
    }

    /// Classifies a failed call to Google's token endpoint. `status` is nil
    /// when no HTTP response arrived at all.
    static func classify(status: Int?, body: Data?) -> Outcome {
        guard let status, status == 400 || status == 401 else { return .transient }
        struct Failure: Decodable { let error: String? }
        let code = body.flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }?.error
        switch code {
        case "invalid_grant", "unauthorized_client", "invalid_client":
            return .revoked
        default:
            return .transient
        }
    }
}
