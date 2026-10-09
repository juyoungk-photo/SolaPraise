//
//  check-oauth-refresh.swift
//  SolaPraise
//
//  Checks which failed token refreshes sign the church account out.
//
//  WHY THIS EXISTS: every failure used to — a timeout, a 503, a rate
//  limit — and signing out deletes the refresh token, so a moment offline
//  cost a fresh sign-in. Only Google's own "this grant is gone" answers
//  should, and the difference is invisible until it bites on a Sunday.
//
//  Run:
//      swiftc -O -o /tmp/oauthcheck \
//          Sources/Auth/OAuthRefresh.swift Tools/check-oauth-refresh.swift
//      /tmp/oauthcheck
//

import Foundation

@main
struct CheckOAuthRefresh {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func body(_ error: String) -> Data { Data("{\"error\":\"\(error)\",\"error_description\":\"x\"}".utf8) }

        check("revoked or expired grant signs out",
              OAuthRefresh.classify(status: 400, body: body("invalid_grant")) == .revoked)
        check("a changed client signs out",
              OAuthRefresh.classify(status: 401, body: body("invalid_client")) == .revoked
              && OAuthRefresh.classify(status: 400, body: body("unauthorized_client")) == .revoked)
        check("no response at all (offline) keeps the grant",
              OAuthRefresh.classify(status: nil, body: nil) == .transient)
        check("server error keeps the grant",
              OAuthRefresh.classify(status: 503, body: Data("<html>".utf8)) == .transient)
        check("rate limit keeps the grant",
              OAuthRefresh.classify(status: 429, body: body("rate_limit_exceeded")) == .transient)
        check("a 400 that is not about the grant keeps it",
              OAuthRefresh.classify(status: 400, body: body("invalid_request")) == .transient)
        check("a 400 with an unreadable body keeps it",
              OAuthRefresh.classify(status: 400, body: Data("oops".utf8)) == .transient)

        print(failures == 0 ? "\nall oauth refresh checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
