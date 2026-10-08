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
//  ── TAB "Live" ───────────────────────────────────────────────
//  Date | CurrentOrder | UpdatedAt | UpdatedBy
//
//  One row per service, rewritten as the service moves. The sheet is a poor
//  transport for this — there is no push, so followers poll and run a few
//  seconds behind. That is fine for "what is next", and not fine for a cue;
//  the screen says which it is rather than implying precision it lacks.
//
//  ── TAB "Plan" ───────────────────────────────────────────────
//  Date | Order | Type | Title | Minutes | Person | Key | YouTubeURL | Notes
//
//  The order of service, which is the thing a 콘티 cannot express. A service
//  is not a list of songs — it is songs interleaved with a welcome, a
//  prayer, a reading, the sermon and a benediction, each with a length, and
//  the useful question on a Sunday morning is "what is next and when does it
//  start". Songs appear here too, carrying their key and link, so there is
//  one timeline rather than two half-orders.
//
//  Optional: a sheet with no Plan tab falls back to Songs, so an existing
//  setup keeps working and gains an order of service whenever it wants one.
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
    /// The order of service. See the note on Plan below.
    static let planTab     = "Plan"
    /// Where the service currently is. One row per date.
    static let liveTab     = "Live"

    enum Schedule { static let date = 0, title = 1, notes = 2, fixedColumns = 3 }
    enum Roles    { static let name = 0, order = 1, active = 2 }
    enum Songs    { static let date = 0, order = 1, title = 2, url = 3, key = 4, transpose = 5, notes = 6 }
    enum Signups  { static let date = 0, role = 1, email = 2, name = 3, status = 4, updatedAt = 5 }
    enum Members  { static let email = 0, name = 1, active = 2 }
    enum Live { static let date = 0, order = 1, updatedAt = 2, by = 3 }
    enum Plan {
        static let date = 0, order = 1, type = 2, title = 3,
                   minutes = 4, person = 5, key = 6, url = 7, notes = 8
    }

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

    /// Clock times as a planner writes them: "11:30 AM", "7:30 PM".
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Dates as people actually type them.
    ///
    /// The sheet is edited by hand, and Sheets reformats what it is given, so
    /// "9/27/2026" and "2026-09-27" both turn up in the same document. Only
    /// the ISO form was accepted, which silently dropped every row of a
    /// schedule typed the ordinary American way — the tab looked empty and
    /// nothing said why.
    private static let dateFormats = [
        "yyyy-MM-dd", "M/d/yyyy", "yyyy/M/d", "M-d-yyyy",
        "MMM d yyyy", "MMM d, yyyy", "d MMM yyyy"
    ]

    /// A planner writes "Oct 4 Sun" — month, day, weekday, no year.
    private static let yearlessFormats = ["MMM d", "M/d", "d MMM"]

    static func day(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Strip a weekday wherever it sits: "Oct 4 Sun", "2026-09-27 (일)".
        if let cut = text.firstIndex(of: "(") {
            text = String(text[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        for weekday in ["Sun","Mon","Tue","Wed","Thu","Fri","Sat",
                        "일","월","화","수","목","금","토"] {
            if text.hasSuffix(" " + weekday) {
                text = String(text.dropLast(weekday.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }

        // No year given. A schedule is about the months ahead, so take the
        // reading that lands nearest to now rather than defaulting to this
        // year and putting next January ten months in the past.
        let calendar = Calendar(identifier: .gregorian)
        let thisYear = calendar.component(.year, from: Date())
        for format in yearlessFormats {
            formatter.dateFormat = format + " yyyy"
            for year in [thisYear, thisYear + 1, thisYear - 1] {
                guard let date = formatter.date(from: "\(text) \(year)") else { continue }
                let days = calendar.dateComponents([.day], from: Date(), to: date).day ?? 0
                if days > -90, days < 300 { return date }
            }
        }
        return nil
    }

    /// Finds a column by any of its accepted names, case-insensitively.
    ///
    /// Every tab is read this way now. A person adds a column, renames one,
    /// or builds a tab by duplicating another — all of which move the
    /// positions this used to count on.
    static func column(_ header: [String], _ names: [String]) -> Int? {
        header.firstIndex {
            names.contains($0.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }
}

// MARK: - Values API

/// The slice of the Sheets values API this needs: read a range, append a row,
/// overwrite a range.
actor SheetsClient {

    enum SheetsError: LocalizedError {
        case notSignedIn
        case noSheet
        case badRange(String)
        case http(Int, String?)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "팀 시트를 열려면 Google 로그인이 필요합니다."
            case .noSheet:     return "팀 시트가 설정되지 않았습니다. 설정에서 시트 주소를 넣어 주세요."
            case .badRange(let range):
                return "시트 범위를 만들 수 없습니다: \(range)"
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

    /// Builds a values URL without letting Foundation encode the range twice.
    ///
    /// `URL.appendingPathComponent` percent-encodes what it is handed, and it
    /// encodes a colon as %3A inside a path segment. A Sheets range is
    /// "Signups!A9:F9" — so every WRITE went out as `Signups!A9%3AF9` and came
    /// back "unable to parse range". Reads were fine because a read asks for a
    /// whole tab, "Signups", which has no colon in it: the sheet loaded
    /// perfectly and nothing could ever be saved, which is exactly how it
    /// looked — a switch that moved and sprang back.
    ///
    /// Setting `path` on URLComponents encodes only what actually needs it and
    /// leaves `:` and `!` alone, which is what the API wants.
    private func valuesURL(sheetId: String, suffix: String) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        // `base` ends in a slash. Appending another one produced
        // "/v4/spreadsheets//<id>/values/..." — a double slash, which the API
        // rejects with a 400 before it ever looks at the range. The old
        // appendingPathComponent handled that for us; building the path by
        // hand means handling it here.
        comps.path = trimmedRoot(comps.path) + "/\(sheetId)/values/\(suffix)"
        return comps.url
    }

    private func trimmedRoot(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Same URL, but for a range that is ALREADY percent-encoded.
    ///
    /// `comps.path` escapes what it is given, which is right for every range
    /// this app writes — until a tab name contains a slash. The church
    /// sheet's tab is "찬양/설교", and a slash in a path is a segment
    /// boundary, not a character: setting `path` leaves it as a separator and
    /// the request asks for a sheet called 찬양 inside a collection called
    /// 설교. Escaping it first and assigning `percentEncodedPath` — which
    /// escapes nothing further — gets it escaped exactly once, the same
    /// once-and-only-once rule the colon bug above is about.
    private func encodedValuesURL(sheetId: String, encodedSuffix: String) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        comps.percentEncodedPath =
            trimmedRoot(comps.path) + "/\(sheetId)/values/\(encodedSuffix)"
        return comps.url
    }

    /// Read a range whose name had to be escaped by the caller.
    func readEncoded(sheetId: String, encodedRange: String) async throws -> [[String]] {
        guard let url = encodedValuesURL(sheetId: sheetId, encodedSuffix: encodedRange),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange(encodedRange) }
        comps.percentEncodedQuery = "valueRenderOption=FORMATTED_VALUE"

        struct Response: Decodable { let values: [[String]]? }
        let data = try await send(url: comps.url!, method: "GET", body: Optional<Data>.none)
        return (try? JSONDecoder().decode(Response.self, from: data))?.values ?? []
    }

    func read(sheetId: String, range: String) async throws -> [[String]] {
        guard let url = valuesURL(sheetId: sheetId, suffix: range),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange(range) }
        // Formatted, so a date the leader typed comes back as they typed it
        // rather than as a serial number.
        comps.queryItems = [.init(name: "valueRenderOption", value: "FORMATTED_VALUE")]

        struct Response: Decodable { let values: [[String]]? }
        let data = try await send(url: comps.url!, method: "GET", body: Optional<Data>.none)
        return (try? JSONDecoder().decode(Response.self, from: data))?.values ?? []
    }

    /// Appends and reports which row it landed on.
    ///
    /// The row number matters: without it the next edit to the same entry has
    /// nowhere to write, and writing to row 0 is an invalid range rather than
    /// a no-op. Google returns it in `updates.updatedRange`.
    @discardableResult
    func append(sheetId: String, tab: String, row: [String]) async throws -> Int? {
        guard let url = valuesURL(sheetId: sheetId, suffix: "\(tab):append"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange(tab) }
        comps.queryItems = [
            .init(name: "valueInputOption", value: "USER_ENTERED"),
            .init(name: "insertDataOption", value: "INSERT_ROWS")
        ]
        struct Body: Encodable { let values: [[String]] }
        let data = try await send(url: comps.url!, method: "POST", body: Body(values: [row]))
        let decoded = try? JSONDecoder().decode(AppendResponse.self, from: data)
        // "Signups!A7:F7" — the first run of digits is the row.
        guard let range = decoded?.updates?.updatedRange,
              let match = range.range(of: "[0-9]+", options: .regularExpression)
        else { return nil }
        return Int(range[match])
    }

    func write(sheetId: String, range: String, row: [String]) async throws {
        guard let url = valuesURL(sheetId: sheetId, suffix: range),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange(range) }
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
        // Built the same way as the others for consistency. This one was
        // never broken: it never ran its path through addingPercentEncoding
        // first, and that double pass — encode the colon to %3A, then encode
        // that percent sign to %25 — is what produced %253A on the writes.
        // The ranges here travel in the JSON body and need no encoding.
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange("batchUpdate") }
        comps.path = trimmedRoot(comps.path) + "/\(sheetId)/values:batchUpdate"
        guard let url = comps.url else { throw SheetsError.badRange("batchUpdate") }
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


private struct AppendResponse: Decodable {
    struct Updates: Decodable { let updatedRange: String? }
    let updates: Updates?
}
