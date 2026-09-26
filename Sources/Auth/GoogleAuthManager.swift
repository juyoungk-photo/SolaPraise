//
//  GoogleAuthManager.swift
//  SolaPraise
//
//  Ported from PraiseTheLord/Sources/GoogleAuthManager.swift.
//  Only the scope set differs: SolaPraise needs read/write access to the
//  signed-in user's own YouTube playlists, not Sheets/Drive.
//
//  Setup (see README):
//    1. SPM package https://github.com/google/GoogleSignIn-iOS
//    2. Google Cloud Console → OAuth client (iOS type) for this bundle id
//    3. Info.plist: GIDClientID + a URL Type whose scheme is the
//       reversed client id
//    4. Enable the **YouTube Data API v3** in the same Cloud project
//
//  NOTE ON TOKEN LIFETIME: while the Cloud project's publishing status is
//  "Testing", Google expires refresh tokens after 7 days, so expect to tap
//  sign-in again about weekly. Submitting the app for verification removes
//  this. `restorePreviousSignIn` handles silent restore in between.
//

import Foundation
import SwiftUI

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
final class GoogleAuthManager: ObservableObject {

    // MARK: - Published state
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var email: String?
    @Published private(set) var displayName: String?
    @Published private(set) var userID: String?          // Google "sub"
    @Published private(set) var avatarURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var isRestoring: Bool = true
    /// Set when the user chooses to carry on without Google. 시편 and the
    /// 말씀 feed need no auth — the psalms are bundled and the feeds are RSS —
    /// so a sign-in wall in front of them is just a dead end.
    @Published var isBrowsingWithoutAccount: Bool = false

    /// Manage the user's own YouTube account: list/create/update playlists
    /// and playlist items. This is a *sensitive* scope — see the note above.
    static let scopes = [
        "https://www.googleapis.com/auth/youtube",
        // Read and write the team's planning sheet. Narrower than
        // `spreadsheets`: this grants access only to files the app itself
        // opened, which for a sheet the leader pasted in means that sheet and
        // nothing else in the person's Drive.
        "https://www.googleapis.com/auth/drive.file"
    ]

    init() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
            Task { @MainActor in
                self?.adopt(user: user)
                self?.isRestoring = false
            }
        }
        #else
        isRestoring = false
        #endif
    }

    // MARK: - Configuration check

    /// True when Info.plist still carries the placeholder client id.
    /// Surfaced in the UI so a missing setup step reads as a clear message
    /// rather than an opaque sign-in failure.
    static var isConfigured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else {
            return false
        }
        return !id.hasPrefix("REPLACE_WITH")
    }

    // MARK: - Sign-in flow

    func signIn() async {
        guard Self.isConfigured else {
            lastError = "Google sign-in is not configured yet. Add your GIDClientID to Info.plist — see README."
            return
        }
        #if canImport(GoogleSignIn)
        guard let presenter = Self.topViewController() else {
            lastError = "No presenter available."
            return
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: Self.scopes
            )
            adopt(user: result.user)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isSignedIn = false
        }
        #else
        lastError = "GoogleSignIn SPM package not added to target."
        #endif
    }

    /// Continue into the app unauthenticated. Features that genuinely need an
    /// account surface their own sign-in prompt where they are used.
    func continueWithoutAccount() {
        isBrowsingWithoutAccount = true
    }

    func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        isSignedIn = false
        isBrowsingWithoutAccount = false
        email = nil
        displayName = nil
        userID = nil
        avatarURL = nil
    }

    // MARK: - Access token for YouTubeAPIClient

    /// Returns a fresh access token, refreshing if needed.
    func accessToken() async throws -> String {
        #if canImport(GoogleSignIn)
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw AuthError.notSignedIn
        }
        let refreshed: GIDGoogleUser = try await withCheckedThrowingContinuation { cont in
            user.refreshTokensIfNeeded { refreshed, error in
                if let error { cont.resume(throwing: error); return }
                if let refreshed { cont.resume(returning: refreshed); return }
                cont.resume(throwing: AuthError.tokenUnavailable)
            }
        }
        return refreshed.accessToken.tokenString
        #else
        throw AuthError.sdkMissing
        #endif
    }

    // MARK: - Private helpers

    #if canImport(GoogleSignIn)
    private func adopt(user: GIDGoogleUser?) {
        guard let user else { isSignedIn = false; return }
        isSignedIn = true
        email = user.profile?.email
        displayName = user.profile?.name
        userID = user.userID
        avatarURL = user.profile?.hasImage == true
            ? user.profile?.imageURL(withDimension: 96)
            : nil
    }
    #endif

    /// Safe lookup of the frontmost UIViewController for presentation.
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive })
                as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    enum AuthError: LocalizedError {
        case notSignedIn, tokenUnavailable, sdkMissing
        var errorDescription: String? {
            switch self {
            case .notSignedIn:      return "Not signed in to Google."
            case .tokenUnavailable: return "Could not obtain Google access token."
            case .sdkMissing:       return "GoogleSignIn SDK not linked."
            }
        }
    }
}
