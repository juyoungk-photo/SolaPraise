//
//  PlanningAuth.swift
//  SolaPraise
//
//  A second Google account, for the team sheet alone.
//
//  WHY A SECOND ONE: the planning sheet belongs to the church account, while
//  YouTube is signed in personally because that is where the playlists and
//  the Premium subscription live. One sign-in cannot be both, and the choice
//  has real consequences either way — sign in as the church and lose your own
//  playlists; sign in personally and every signup is recorded under the wrong
//  identity.
//
//  WHY NOT GoogleSignIn: its SDK holds exactly one `currentUser`. Signing a
//  second account in through it would sign the first one out. So this talks
//  to Google's OAuth endpoints directly, with PKCE as Google requires for an
//  installed app — no client secret, which is why that is safe to ship.
//
//  The refresh token is the long-lived credential here and lives in the
//  keychain, never in UserDefaults.
//

import AuthenticationServices
import CryptoKit
import Foundation

@MainActor
final class PlanningAuth: NSObject, ObservableObject {

    @Published private(set) var email: String?
    @Published private(set) var isSignedIn = false
    @Published var lastError: String?

    static let scopes = [
        "https://www.googleapis.com/auth/spreadsheets",
        "openid", "email"
    ]

    private var accessToken: String?
    private var expiry: Date?
    private var session: ASWebAuthenticationSession?

    private static let emailKey = "planning.email"
    private static let keychainAccount = "planning.refreshToken"

    private var clientId: String {
        Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
    }
    private var redirectURI: String {
        let reversed = clientId
            .split(separator: ".")
            .reversed()
            .joined(separator: ".")
        return "\(reversed):/oauth"
    }

    override init() {
        super.init()
        email = UserDefaults.standard.string(forKey: Self.emailKey)
        isSignedIn = email != nil && Keychain.read(Self.keychainAccount) != nil
    }

    // MARK: - Sign in

    func signIn() async {
        guard !clientId.isEmpty else {
            lastError = "GIDClientID가 Info.plist에 없습니다."
            return
        }
        let verifier = Self.randomVerifier()
        guard let challenge = Self.challenge(for: verifier) else { return }

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Forces the chooser, which is the entire point: the account
            // already signed in for YouTube must not be picked silently.
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "access_type", value: "offline")
        ]
        guard let url = comps.url else { return }

        let callbackScheme = String(redirectURI.split(separator: ":").first ?? "")
        let code: String? = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callback, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code
                        == .canceledLogin
                    if !cancelled { self.lastError = error.localizedDescription }
                    continuation.resume(returning: nil)
                    return
                }
                let value = callback
                    .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first { $0.name == "code" }?.value
                continuation.resume(returning: value)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        guard let code else { return }
        await exchange(code: code, verifier: verifier)
    }

    func signOut() {
        Keychain.delete(Self.keychainAccount)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        accessToken = nil
        expiry = nil
        email = nil
        isSignedIn = false
    }

    // MARK: - Tokens

    /// A valid access token, refreshing when needed.
    func token() async throws -> String {
        if let accessToken, let expiry, expiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let refresh = Keychain.read(Self.keychainAccount) else {
            throw SheetsClient.SheetsError.notSignedIn
        }
        try await refreshToken(refresh)
        guard let accessToken else { throw SheetsClient.SheetsError.notSignedIn }
        return accessToken
    }

    private func exchange(code: String, verifier: String) async {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirectURI)
        ]
        guard let response: TokenResponse = await post(body) else { return }

        accessToken = response.access_token
        expiry = Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3000))
        if let refresh = response.refresh_token {
            Keychain.write(Self.keychainAccount, value: refresh)
        }
        if let address = response.id_token.flatMap(Self.email(fromIDToken:)) {
            email = address
            UserDefaults.standard.set(address, forKey: Self.emailKey)
        }
        isSignedIn = Keychain.read(Self.keychainAccount) != nil
        lastError = nil
    }

    private func refreshToken(_ refresh: String) async throws {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "refresh_token", value: refresh),
            .init(name: "grant_type", value: "refresh_token")
        ]
        guard let response: TokenResponse = await post(body) else {
            // A refresh token is revoked by the user or expires after the
            // app sits in Testing for a week. Either way it is gone, and
            // pretending otherwise just fails on every later call.
            signOut()
            throw SheetsClient.SheetsError.notSignedIn
        }
        accessToken = response.access_token
        expiry = Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3000))
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int?
    }

    private func post(_ body: URLComponents) async -> TokenResponse? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                lastError = String(data: data, encoding: .utf8)?.prefix(160).description
                return nil
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - PKCE

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func challenge(for verifier: String) -> String? {
        guard let data = verifier.data(using: .ascii) else { return nil }
        return Data(SHA256.hash(data: data)).base64URLEncoded
    }

    /// The payload of a Google id_token, which arrived over TLS straight from
    /// the token endpoint — so it is read, not verified.
    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }
}

extension PlanningAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
