//
//  TeamSheet.swift
//  SolaPraise
//
//  The team's master Google Sheet: what it looks like, and how to read and
//  write it.
//
//  Ported from PraiseTheLord, which built this for exactly the job now being
//  asked of SolaPraise. A sheet rather than a backend because the team
//  already lives in one: whoever leads can open it in a browser and rearrange
//  a Sunday without the app, and nobody has to be persuaded to adopt a
//  service. The app is a better window onto it, not a replacement for it.
//
//  ── TAB "Schedule" ───────────────────────────────────────────
//  Date | Title | Notes | <role-1> | <role-2> | …
//  One row per service. A role cell holds the assigned member's name.
//
//  ── TAB "Roles" ──────────────────────────────────────────────
//  Role | Order | Active
//
//  ── TAB "Songs" ──────────────────────────────────────────────
//  Date | Order | Title | YouTubeURL | Key | Transpose | Notes
//
//  ── TAB "Signups" ────────────────────────────────────────────
//  Date | Role | MemberEmail | MemberName | Status | UpdatedAt
//
//  ── TAB "Members" ────────────────────────────────────────────
//  Email | Name | Active
//  Who the 예배 준비 tab appears for. See TeamAccess for what that does
//  and, more importantly, what it does not do.
//
//  NOTE: these are the addresses people sign into the APP with, which is
//  often not the address that owns the sheet. A church account commonly owns
//  the document while members sign in personally — so the owner must share
//  the sheet with each member's own address as an editor, and that address is
//  what belongs here. Link sharing is not enough: it grants reading, and a
//  signup is a write.
//

import Foundation

enum TeamSheet {

    static let scheduleTab = "Schedule"
    static let rolesTab    = "Roles"
    static let songsTab    = "Songs"
    static let signupsTab  = "Signups"
    static let membersTab  = "Members"

    enum Schedule { static let date = 0, title = 1, notes = 2, fixedColumns = 3 }
    enum Roles    { static let name = 0, order = 1, active = 2 }
    enum Songs    { static let date = 0, order = 1, title = 2, url = 3, key = 4, transpose = 5, notes = 6 }
    enum Signups  { static let date = 0, role = 1, email = 2, name = 3, status = 4, updatedAt = 5 }
    enum Members  { static let email = 0, name = 1, active = 2 }

    /// ISO-8601 with the date only, so Sheets cannot silently reinterpret it
    /// as one of its own date types and hand back a serial number.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ raw: String) -> Date? {
        dateFormatter.date(from: String(raw.prefix(10)))
    }
}

// MARK: - Values API

/// The slice of the Sheets values API this needs: read a range, append a row,
/// overwrite a range.
actor SheetsClient {

    enum SheetsError: LocalizedError {
        case notSignedIn
        case noSheet
        case http(Int, String?)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "팀 시트를 열려면 Google 로그인이 필요합니다."
            case .noSheet:     return "팀 시트가 설정되지 않았습니다. 설정에서 시트 주소를 넣어 주세요."
            case .http(404, _):
                return "시트를 찾을 수 없습니다. 주소와 공유 설정을 확인해 주세요."
            case .http(403, let message):
                // Google says which of these it is, in prose, and the three
                // fixes have nothing in common — one is a console switch, one
                // is re-consenting, one is a sharing change. Guessing wrong
                // costs an evening, so read what it actually said.
                let text = message ?? ""
                if text.contains("has not been used in project")
                    || text.contains("is disabled")
                    || text.contains("SERVICE_DISABLED") {
                    return "Google Sheets API가 이 프로젝트에서 켜져 있지 않습니다. Cloud Console → API 및 서비스 → 라이브러리에서 Google Sheets API를 사용 설정하세요. 새 사용자 인증 정보를 만들 필요는 없습니다."
                }
                if text.contains("insufficient authentication scopes")
                    || text.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") {
                    return "로그인 토큰에 시트 권한이 없습니다. 「시트 권한 허용」을 누르거나 다시 로그인하세요. 그래도 같으면 OAuth 동의 화면에 spreadsheets 범위를 추가해야 합니다."
                }
                return "시트를 열 권한이 없습니다. 이 계정이 시트를 편집할 수 있는지 확인하세요. (\(text.isEmpty ? "사유 불명" : text))"
            case .http(let code, let message):
                return message ?? "시트 오류 (\(code))"
            case .transport(let error): return error.localizedDescription
            }
        }
    }

    private let base = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/")!
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String

    init(session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () async throws -> String) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func read(sheetId: String, range: String) async throws -> [[String]] {
        let encoded = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        var comps = URLComponents(
            url: base.appendingPathComponent("\(sheetId)/values/\(encoded)"),
            resolvingAgainstBaseURL: false
        )!
        // Formatted, so a date the leader typed comes back as they typed it
        // rather than as a serial number.
        comps.queryItems = [.init(name: "valueRenderOption", value: "FORMATTED_VALUE")]

        struct Response: Decodable { let values: [[String]]? }
        let data = try await send(url: comps.url!, method: "GET", body: Optional<Data>.none)
        return (try? JSONDecoder().decode(Response.self, from: data))?.values ?? []
    }

    func append(sheetId: String, tab: String, row: [String]) async throws {
        let encoded = tab.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tab
        var comps = URLComponents(
            url: base.appendingPathComponent("\(sheetId)/values/\(encoded):append"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            .init(name: "valueInputOption", value: "USER_ENTERED"),
            .init(name: "insertDataOption", value: "INSERT_ROWS")
        ]
        struct Body: Encodable { let values: [[String]] }
        _ = try await send(url: comps.url!, method: "POST", body: Body(values: [row]))
    }

    func write(sheetId: String, range: String, row: [String]) async throws {
        let encoded = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        var comps = URLComponents(
            url: base.appendingPathComponent("\(sheetId)/values/\(encoded)"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [.init(name: "valueInputOption", value: "USER_ENTERED")]
        struct Body: Encodable { let values: [[String]] }
        _ = try await send(url: comps.url!, method: "PUT", body: Body(values: [row]))
    }

    /// Several ranges in one request.
    ///
    /// Pushing a 콘티 rewrites one row per song, and doing that as separate
    /// PUTs would be a dozen round trips and a dozen chances to leave the
    /// sheet half-written.
    func batchWrite(sheetId: String, updates: [(range: String, rows: [[String]])]) async throws {
        guard !updates.isEmpty else { return }
        struct ValueRange: Encodable { let range: String; let values: [[String]] }
        struct Body: Encodable {
            let valueInputOption: String
            let data: [ValueRange]
        }
        let url = base.appendingPathComponent("\(sheetId)/values:batchUpdate")
        _ = try await send(
            url: url,
            method: "POST",
            body: Body(
                valueInputOption: "USER_ENTERED",
                data: updates.map { ValueRange(range: $0.range, values: $0.rows) }
            )
        )
    }

    // MARK: - Transport

    private func send<B: Encodable>(url: URL, method: String, body: B?) async throws -> Data {
        let token: String
        do { token = try await tokenProvider() }
        catch { throw SheetsError.notSignedIn }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw SheetsError.transport(error) }

        guard let http = response as? HTTPURLResponse else {
            throw SheetsError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(SheetsFailure.self, from: data))?
                .error?.message
            throw SheetsError.http(http.statusCode, message)
        }
        return data
    }
}


/// Google's error envelope, hoisted out of the generic send so it can be a
/// type at all — Swift does not allow a nested type in a generic function.
private struct SheetsFailure: Decodable {
    struct Inner: Decodable { let message: String? }
    let error: Inner?
}
