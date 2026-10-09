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
    /// 악보 and other files attached to a service's songs.
    ///
    /// ── TAB "Attachments" ────────────────────────────────────
    /// Date | Song | Name | FileId | URL | AddedBy | AddedAt
    ///
    /// A tab rather than a column on Songs, because a song can have several
    /// — a lead sheet, a chord chart, a page of lyrics — and a cell that
    /// holds a list is a cell nobody can edit by hand. One row per file
    /// keeps the sheet readable and lets a leader delete one by clearing a
    /// line, which is how everything else in this document works.
    ///
    /// `Song` empty means the file belongs to the SERVICE rather than to any
    /// one song: the combined 콘티 PDF is filed that way.
    static let attachmentsTab = "Attachments"

    /// The Schedule tab's shared-playlist column, however it is spelled.
    ///
    /// Optional: a sheet without it simply has no shared playlist, and the
    /// app offers to create one, which adds the column's value for that row
    /// only — it never inserts a column into somebody else's document.
    static let playlistColumnNames = ["playlist", "재생목록", "콘티", "플레이리스트"]

    enum Schedule { static let date = 0, title = 1, notes = 2, fixedColumns = 3 }
    enum Roles    { static let name = 0, order = 1, active = 2 }
    enum Songs    { static let date = 0, order = 1, title = 2, url = 3, key = 4, transpose = 5, notes = 6 }
    enum Signups  { static let date = 0, role = 1, email = 2, name = 3, status = 4, updatedAt = 5 }
    enum Members  { static let email = 0, name = 1, active = 2 }
    enum Live { static let date = 0, order = 1, updatedAt = 2, by = 3 }
    enum Attachments {
        static let date = 0, song = 1, name = 2,
                   fileId = 3, url = 4, addedBy = 5, addedAt = 6
        static let width = 7
        static let header = ["Date", "Song", "Name", "FileId", "URL", "AddedBy", "AddedAt"]
    }
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

    /// 0-based column index to A1 letters: 0 → "A", 25 → "Z", 26 → "AA".
    ///
    /// A Schedule tab with a column per role gets wide, and the old
    /// single-letter arithmetic silently wrote to Z for everything past it.
    static func columnLetter(_ index: Int) -> String {
        guard index >= 0 else { return "A" }
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    /// A row whose contents sit too far to the right.
    struct ShiftedRow: Equatable, Identifiable {
        let row: Int            // 1-based
        let shift: Int          // columns too far right
        let repaired: [String]  // the same cells, moved back
        var id: Int { row }
    }

    /// Rows that hold a date, but not in the Date column.
    ///
    /// The fingerprint of the append bug: everything to the left of the
    /// date is empty and the date is where it should not be. Such a row is
    /// invisible to every parser — they all read the date from its own
    /// column — so its song is gone from the 콘티 with no error anywhere.
    /// Detecting it is what turns silent loss into something a person can
    /// see and fix.
    static func shiftedRows(in rows: [[String]]) -> [ShiftedRow] {
        guard let header = rows.first else { return [] }
        let dateColumn = column(header, ["date", "날짜"]) ?? 0
        var out: [ShiftedRow] = []
        for (offset, cells) in rows.enumerated() where offset > 0 {
            if cells.count > dateColumn, day(cells[dateColumn]) != nil { continue }
            guard let first = cells.firstIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }), first > dateColumn, day(cells[first]) != nil else { continue }

            let shift = first - dateColumn
            out.append(ShiftedRow(row: offset + 1, shift: shift,
                                  repaired: Array(cells.dropFirst(shift))))
        }
        return out
    }

    // MARK: Songs entered more than once

    /// The same song more than once on one service, and how to tidy it.
    struct DuplicateSongs: Equatable {
        struct Renumber: Equatable { let row: Int; let order: Int }
        /// 1-based rows to clear: every copy after the first.
        let rows: [Int]
        /// Order cells to rewrite so each affected service runs 1…n again.
        let renumber: [Renumber]
        var isEmpty: Bool { rows.isEmpty }
    }

    /// Every copy after the first of a song on the same date.
    ///
    /// A song is the same when its video is the same; without a link, when
    /// its title is. The first copy — the highest on the sheet — is the one
    /// kept, because it is the one somebody added deliberately.
    ///
    /// WHY THIS EXISTS: a real 콘티 ended up with one video seven times, its
    /// Order cells reading 4, 5, 4, 5, 4, 6, 7. Each add was made while the
    /// earlier copies were invisible — written into the wrong columns — so
    /// each looked like the first, and nothing on screen said otherwise.
    ///
    /// The renumbering only touches numeric Order cells. A 헌금찬양 written
    /// in the Order column is a label the team chose, not a position.
    static func duplicateSongRows(in rows: [[String]]) -> DuplicateSongs {
        guard let header = rows.first else { return DuplicateSongs(rows: [], renumber: []) }
        let dateColumn = column(header, ["date", "날짜"]) ?? 0
        let orderColumn = column(header, ["order", "순서", "#"]) ?? 1
        let titleColumn = column(header, ["title", "곡", "곡명", "찬양"]) ?? 2
        let urlColumn = column(header, ["youtubeurl", "url", "link", "링크", "영상"])

        func cell(_ cells: [String], _ index: Int?) -> String {
            guard let index, cells.indices.contains(index) else { return "" }
            return cells[index].trimmingCharacters(in: .whitespaces)
        }

        var seen: Set<String> = []
        var duplicates: [Int] = []
        var kept: [String: [(row: Int, order: Int?)]] = [:]
        var affected: Set<String> = []

        for (offset, cells) in rows.enumerated() where offset > 0 {
            guard let date = day(cell(cells, dateColumn)) else { continue }
            let title = cell(cells, titleColumn)
            guard !title.isEmpty else { continue }
            let dayKey = dateFormatter.string(from: date)
            let song = videoKey(cell(cells, urlColumn))
                ?? title.lowercased().filter { !$0.isWhitespace }
            let row = offset + 1
            if seen.insert(dayKey + "|" + song).inserted {
                kept[dayKey, default: []].append((row, Int(cell(cells, orderColumn))))
            } else {
                duplicates.append(row)
                affected.insert(dayKey)
            }
        }

        var renumber: [DuplicateSongs.Renumber] = []
        for dayKey in affected.sorted() {
            let numbered = (kept[dayKey] ?? [])
                .compactMap { entry in entry.order.map { (row: entry.row, order: $0) } }
                .sorted { $0.order != $1.order ? $0.order < $1.order : $0.row < $1.row }
            for (index, entry) in numbered.enumerated() where entry.order != index + 1 {
                renumber.append(.init(row: entry.row, order: index + 1))
            }
        }
        return DuplicateSongs(rows: duplicates, renumber: renumber.sorted { $0.row < $1.row })
    }

    /// The YouTube video id in a link, in any of the shapes links take.
    static func videoKey(_ link: String) -> String? {
        let patterns = ["[?&]v=([A-Za-z0-9_-]{11})", "youtu\\.be/([A-Za-z0-9_-]{11})",
                        "/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
                  let range = Range(match.range(at: 1), in: link) else { continue }
            return String(link[range])
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
        // NOT values:append. That call writes "starting with the first
        // column of the TABLE" it detects — not at column A — and its
        // detection is thrown off by blank rows in the middle of a tab.
        // Once one row landed in column C, the detected table started at C
        // and every later append followed it: the team's Songs tab ended up
        // with nine songs whose date sat in the Order column, two columns
        // right, where nothing reads it. They simply vanished from the
        // 콘티, and switching account looked like it changed the 순서 only
        // because the reload exposed what the sheet really held.
        //
        // So the line is computed here and written to an explicit range
        // anchored at A. The values API trims trailing empty rows, so the
        // count of what comes back is the last line in use; interior blank
        // rows are left alone rather than refilled, which keeps every
        // existing row number stable.
        //
        // The cost is a race INSERT_ROWS did not have: two people appending
        // to the same tab in the same second could pick the same line. The
        // target is re-checked immediately before writing to make that
        // window as narrow as one round trip, and for a worship team it is
        // a far smaller risk than silent, self-perpetuating column drift.
        let lastColumn = TeamSheet.columnLetter(max(row.count, 1) - 1)
        for _ in 0..<4 {
            let existing = try await read(sheetId: sheetId, range: tab)
            let target = max(existing.count, 1) + 1
            let range = "\(tab)!A\(target):\(lastColumn)\(target)"

            let occupant = try await read(sheetId: sheetId, range: range)
            let taken = occupant.first?.contains {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            } ?? false
            guard !taken else { continue }

            try await write(sheetId: sheetId, range: range, row: row)
            return target
        }
        throw SheetsError.badRange("\(tab): no free row after several tries")
    }

    func write(sheetId: String, range: String, row: [String]) async throws {
        guard let url = valuesURL(sheetId: sheetId, suffix: range),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange(range) }
        comps.queryItems = [.init(name: "valueInputOption", value: "USER_ENTERED")]
        struct Body: Encodable { let values: [[String]] }
        _ = try await send(url: comps.url!, method: "PUT", body: Body(values: [row]))
    }

    /// Adds a tab.
    ///
    /// A new TAB is safe where a new COLUMN is not: a column insert shifts
    /// everything to its right in a document the whole team edits by hand,
    /// while a tab cannot disturb anything that already exists. This is why
    /// attachments get their own tab rather than a column on Songs.
    ///
    /// batchUpdate, not the values API — creating a sheet is structure, not
    /// content.
    func addSheet(sheetId: String, title: String) async throws {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange(title) }
        comps.path = trimmedRoot(comps.path) + "/\(sheetId):batchUpdate"
        guard let url = comps.url else { throw SheetsError.badRange(title) }

        struct Request: Encodable {
            struct AddSheet: Encodable {
                struct Properties: Encodable { let title: String }
                let properties: Properties
            }
            struct Item: Encodable { let addSheet: AddSheet }
            let requests: [Item]
        }
        let body = Request(requests: [
            .init(addSheet: .init(properties: .init(title: title)))
        ])
        _ = try await send(url: url, method: "POST", body: body)
    }

    /// Each tab's id, size, frozen rows and existing colour rules, plus the
    /// header row of every tab SheetTidy knows — what it needs to decide
    /// what to change and what is already there.
    func tidyTabs(sheetId: String) async throws -> [SheetTidy.Tab] {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange("tidy") }
        comps.path = trimmedRoot(comps.path) + "/\(sheetId)"
        comps.queryItems = [.init(
            name: "fields",
            value: "sheets(properties(sheetId,title,gridProperties(frozenRowCount,columnCount)),conditionalFormats(booleanRule(condition(values(userEnteredValue)))))")]
        guard let url = comps.url else { throw SheetsError.badRange("tidy") }

        struct Spreadsheet: Decodable {
            struct Sheet: Decodable {
                struct Properties: Decodable {
                    struct Grid: Decodable { let frozenRowCount: Int?; let columnCount: Int? }
                    let sheetId: Int
                    let title: String
                    let gridProperties: Grid?
                }
                struct Format: Decodable {
                    struct Rule: Decodable {
                        struct Condition: Decodable {
                            struct Value: Decodable { let userEnteredValue: String? }
                            let values: [Value]?
                        }
                        let condition: Condition?
                    }
                    let booleanRule: Rule?
                }
                let properties: Properties
                let conditionalFormats: [Format]?
            }
            let sheets: [Sheet]?
        }
        let data = try await send(url: url, method: "GET", body: Optional<String>.none)
        let decoded = try JSONDecoder().decode(Spreadsheet.self, from: data)

        var tabs: [SheetTidy.Tab] = []
        for sheet in decoded.sheets ?? [] where SheetTidy.knownTabs.contains(sheet.properties.title) {
            let header = (try? await read(sheetId: sheetId,
                                          range: "\(sheet.properties.title)!1:1"))?.first ?? []
            let formulas = (sheet.conditionalFormats ?? []).flatMap {
                ($0.booleanRule?.condition?.values ?? []).compactMap(\.userEnteredValue)
            }
            tabs.append(SheetTidy.Tab(
                gid: sheet.properties.sheetId,
                title: sheet.properties.title,
                header: header,
                columnCount: sheet.properties.gridProperties?.columnCount ?? header.count,
                frozenRows: sheet.properties.gridProperties?.frozenRowCount ?? 0,
                existingFormulas: Set(formulas)))
        }
        return tabs
    }

    /// Formatting-only batchUpdate. The requests are built by SheetTidy as
    /// JSON objects, since they are a mix of shapes Codable would need a
    /// type apiece for.
    func formatUpdate(sheetId: String, requests: [[String: Any]]) async throws {
        guard !requests.isEmpty else { return }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw SheetsError.badRange("tidy") }
        comps.path = trimmedRoot(comps.path) + "/\(sheetId):batchUpdate"
        guard let url = comps.url else { throw SheetsError.badRange("tidy") }
        let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
        _ = try await send(url: url, method: "POST", rawBody: body)
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
        try await send(url: url, method: method,
                       rawBody: body.flatMap { try? JSONEncoder().encode($0) })
    }

    private func send(url: URL, method: String, rawBody: Data?) async throws -> Data {
        let token: String
        do { token = try await tokenProvider() }
        catch { throw SheetsError.notSignedIn }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let rawBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = rawBody
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



// MARK: - Playlist ids

/// A YouTube playlist id out of whatever a leader pasted into the cell.
enum YouTubePlaylistID {
    static func from(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A bare id: PL…, UU…, LL…, FL…, OLAK5uy_…
        if !text.contains("/"), !text.contains(" ") { return text }
        guard let range = text.range(of: "[?&]list=([A-Za-z0-9_-]+)",
                                     options: .regularExpression) else { return nil }
        return String(text[range].drop(while: { $0 != "=" }).dropFirst())
    }

    static func url(_ id: String) -> URL? {
        URL(string: "https://www.youtube.com/playlist?list=\(id)")
    }
}
