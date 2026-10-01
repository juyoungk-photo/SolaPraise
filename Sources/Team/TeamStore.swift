//
//  TeamStore.swift
//  SolaPraise
//
//  One Sunday's worth of preparation, read from the team sheet.
//
//  This is the thing a playlist cannot be. A playlist is an ordered list of
//  videos; a service also has a date, a set of roles, who filled them, the
//  key each song is actually played in, and the notes the leader left. The
//  sheet already holds all of it, so the app's job is to show it in the order
//  a musician needs it and to let a member sign up without leaving.
//

import Foundation
import SwiftUI

// MARK: - What a service is made of

struct TeamRole: Identifiable, Hashable {
    let name: String
    let order: Double
    var id: String { name }
}

struct TeamSong: Identifiable, Hashable {
    let order: Int
    let title: String
    let url: URL?
    /// The key the team plays it in, as the leader typed it. Authoritative
    /// over anything detection produces.
    let key: String?
    let transpose: Int
    let notes: String?
    var id: String { "\(order)-\(title)" }

    var videoId: String? { url.flatMap { YouTubeID.parse($0.absoluteString) } }
}

/// One line in the order of service.
struct PlanItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case song, prayer, reading, sermon, announcement, offering, transition, other

        init(raw: String) {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch key {
            case "song", "찬양", "곡":            self = .song
            case "prayer", "기도":                self = .prayer
            case "reading", "말씀", "성경봉독":    self = .reading
            case "sermon", "설교":                self = .sermon
            case "announcement", "광고", "환영":   self = .announcement
            case "offering", "헌금", "봉헌":       self = .offering
            case "transition", "전환", "간주":     self = .transition
            default:                              self = Kind(rawValue: key) ?? .other
            }
        }

        var label: String {
            switch self {
            case .song:         return "찬양"
            case .prayer:       return "기도"
            case .reading:      return "말씀"
            case .sermon:       return "설교"
            case .announcement: return "광고"
            case .offering:     return "헌금"
            case .transition:   return "전환"
            case .other:        return "순서"
            }
        }

        var symbolName: String {
            switch self {
            case .song:         return "music.note"
            case .prayer:       return "hands.and.sparkles"
            case .reading:      return "book.closed"
            case .sermon:       return "text.bubble"
            case .announcement: return "megaphone"
            case .offering:     return "basket"
            case .transition:   return "arrow.right"
            case .other:        return "circle"
            }
        }
    }

    let order: Int
    let kind: Kind
    let title: String
    /// Planned length. Nil means nobody has estimated it, which is different
    /// from zero and must not be added into a running time as if it were.
    let minutes: Int?
    let person: String?
    let key: String?
    let url: URL?
    let notes: String?
    /// 1-based row, so an edit rewrites in place.
    let row: Int?

    var id: String { "\(order)-\(title)" }
    var videoId: String? { url.flatMap { YouTubeID.parse($0.absoluteString) } }
}

/// What a member said about one service.
///
/// 자리비움 is deliberately separate from 어려움. "I cannot do this Sunday"
/// and "I am away for a month" need different responses from a leader, and
/// collapsing them into one word loses the distinction that decides whether
/// to ask again next week.
enum SignupStatus: String {
    case available, declined, away

    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "declined", "불가", "어려움": self = .declined
        case "away", "자리비움", "부재":    self = .away
        default:                          self = .available
        }
    }

    var label: String {
        switch self {
        case .available: return "가능"
        case .declined:  return "어려움"
        case .away:      return "자리비움"
        }
    }
}

struct TeamSignup: Identifiable, Hashable {
    let role: String
    let email: String
    let name: String
    let statusRaw: String
    /// 1-based row on the Signups tab, so an update rewrites in place rather
    /// than appending a second opinion.
    ///
    /// Optional because a signup created in this session has no row until
    /// the append reports one. It used to default to 0, and the next edit
    /// then addressed "A0:F0" — an invalid range, which failed silently and
    /// made the buttons look like they had stopped toggling after the first
    /// tap.
    let row: Int?
    var id: String { "\(role)|\(email)" }

    var status: SignupStatus { SignupStatus(raw: statusRaw) }
    var isAvailable: Bool { status == .available }
}

struct TeamService: Identifiable, Hashable {
    let date: Date
    let title: String
    let notes: String?
    /// Role name → assigned member, as filled in on the Schedule tab.
    let assignments: [String: String]
    var id: Date { date }

    var isPast: Bool { date < Calendar.current.startOfDay(for: Date()) }
}

// MARK: - Store

@MainActor
final class TeamStore: ObservableObject {

    @Published private(set) var services: [TeamService] = []
    @Published private(set) var roles: [TeamRole] = []
    @Published private(set) var songs: [Date: [TeamSong]] = [:]
    @Published private(set) var plans: [Date: [PlanItem]] = [:]

    /// Where each service currently is, and who last said so.
    @Published private(set) var liveOrder: [Date: Int] = [:]
    @Published private(set) var liveUpdatedBy: [Date: String] = [:]
    /// The sheet row holding that, so advancing rewrites rather than appends.
    private var liveRows: [Date: Int] = [:]
    @Published private(set) var signups: [Date: [TeamSignup]] = [:]
    @Published private(set) var memberEmails: Set<String> = []

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastLoaded: Date?

    /// Set when a write comes back 403 while reads are fine.
    ///
    /// The sheet is commonly owned by the church's account while people sign
    /// in with their own, so "can read" and "can write" are genuinely
    /// separate here: link sharing gives everyone the first and nobody the
    /// second. Signing up silently failing would be the worst version of
    /// that, so it is stated and the buttons stop pretending.
    @Published private(set) var isReadOnly = false

    /// Set when even a READ comes back 403.
    ///
    /// With the sheet shared to anyone-with-the-link, a refused read cannot
    /// be about the document — it is the token missing the scope. Inferring
    /// that from `grantedScopes` alone proved unreliable on a restored
    /// session, so the server's answer is treated as the authority.
    @Published var needsAuthorization = false

    private var client: SheetsClient?

    func configure(auth: GoogleAuthManager) {
        guard client == nil else { return }
        client = SheetsClient { try await auth.accessToken() }
    }

    /// The next service that has not happened yet, which is what anyone
    /// opening this tab is almost always here for.
    var upcoming: TeamService? {
        services.first { !$0.isPast } ?? services.last
    }

    /// The order of service, or the 콘티 promoted into one.
    ///
    /// A sheet without a Plan tab still has songs, and a list of songs is a
    /// perfectly good order of service for a team that only plans music — so
    /// it is shown as one rather than showing nothing.
    func plan(for service: TeamService) -> [PlanItem] {
        let day = Calendar.current.startOfDay(for: service.date)
        if let items = plans[day], !items.isEmpty {
            return items.sorted { $0.order < $1.order }
        }
        return songs(for: service).map {
            PlanItem(order: $0.order, kind: .song, title: $0.title,
                     minutes: nil, person: nil, key: $0.key, url: $0.url,
                     notes: $0.notes, row: nil)
        }
    }

    var hasPlanTab: Bool { !plans.isEmpty }

    /// Clock times for a plan, from a start time and the planned lengths.
    ///
    /// An item with no length does not advance the clock, and everything
    /// after an unestimated item is therefore approximate — which is honest,
    /// and better than inventing a duration to keep the arithmetic tidy.
    static func startTimes(for items: [PlanItem], from start: Date) -> [String: Date] {
        var out: [String: Date] = [:]
        var cursor = start
        for item in items {
            out[item.id] = cursor
            guard let minutes = item.minutes, minutes > 0 else { continue }
            cursor = cursor.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return out
    }

    func songs(for service: TeamService) -> [TeamSong] {
        (songs[Calendar.current.startOfDay(for: service.date)] ?? [])
            .sorted { $0.order < $1.order }
    }

    func signups(for service: TeamService, role: String) -> [TeamSignup] {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .filter { $0.role == role && $0.isAvailable }
    }

    /// Every response for a role, whatever it said.
    func signupsAll(for service: TeamService, role: String) -> [TeamSignup] {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .filter { $0.role == role }
    }

    func mySignup(for service: TeamService, role: String, email: String) -> TeamSignup? {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .first { $0.role == role && $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    // MARK: - Loading

    func load(sheetId: String) async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Four reads rather than one batch: each tab is parsed
            // differently and a failure in one should not lose the others.
            async let scheduleRows = client.read(sheetId: sheetId, range: TeamSheet.scheduleTab)
            async let roleRows     = client.read(sheetId: sheetId, range: TeamSheet.rolesTab)
            async let songRows     = client.read(sheetId: sheetId, range: TeamSheet.songsTab)
            async let signupRows   = client.read(sheetId: sheetId, range: TeamSheet.signupsTab)

            let (schedule, roleData, songData, signupData) =
                try await (scheduleRows, roleRows, songRows, signupRows)

            // Optional tab: absent on a sheet made before the order of
            // service existed, which must keep working.
            let planData = (try? await client.read(sheetId: sheetId, range: TeamSheet.planTab)) ?? []
            plans = Self.parsePlan(planData)

            roles = Self.parseRoles(roleData)
            services = Self.parseSchedule(schedule, roles: roles)
            songs = Self.parseSongs(songData)
            signups = Self.parseSignups(signupData)
            memberEmails = await loadMembers(sheetId: sheetId, client: client)
            lastLoaded = Date()
            needsAuthorization = false
        } catch SheetsClient.SheetsError.http(403, let message) {
            needsAuthorization = true
            errorMessage = message ?? "시트를 읽을 권한이 없습니다."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Members tab is optional. Without one, anyone who can open the
    /// sheet counts as a member — which is the same thing, since Google's own
    /// sharing is what actually protects it.
    private func loadMembers(sheetId: String, client: SheetsClient) async -> Set<String> {
        guard let rows = try? await client.read(sheetId: sheetId, range: TeamSheet.membersTab),
              rows.count > 1 else { members = []; return [] }

        var emails: Set<String> = []
        var list: [Member] = []
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > TeamSheet.Members.email else { continue }
            let email = row[TeamSheet.Members.email].trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty, email.contains("@") else { continue }
            let activeCell = row.count > TeamSheet.Members.active
                ? row[TeamSheet.Members.active].lowercased()
                : "true"
            let active = !["false", "no", "n", "0"].contains(activeCell)
            let name = row.count > TeamSheet.Members.name ? row[TeamSheet.Members.name] : ""
            list.append(Member(email: email, name: name, isActive: active, row: offset + 1))
            if active { emails.insert(email.lowercased()) }
        }
        members = list
        return emails
    }

    // MARK: - Signing up

    /// Records availability, rewriting the member's existing row when they
    /// already answered — otherwise saying yes then no would leave both.
    /// Everyone on the roster who has not answered for this service.
    ///
    /// The leader's real question is not who said yes — it is who has said
    /// nothing, because that is the list to go and ask. Members who are away
    /// have answered and are not chased.
    func unanswered(for service: TeamService) -> [String] {
        guard !memberEmails.isEmpty else { return [] }
        let day = Calendar.current.startOfDay(for: service.date)
        let answered = Set((signups[day] ?? []).map { $0.email.lowercased() })
        return memberEmails.subtracting(answered).sorted()
    }

    func responses(for service: TeamService) -> [TeamSignup] {
        let day = Calendar.current.startOfDay(for: service.date)
        // One line per person, not per role, which is how a leader reads it.
        var seen: [String: TeamSignup] = [:]
        for signup in signups[day] ?? [] {
            seen[signup.email.lowercased()] = signup
        }
        return seen.values.sorted { $0.name < $1.name }
    }

    func setAvailability(
        _ status: SignupStatus,
        service: TeamService,
        role: String,
        email: String,
        name: String,
        sheetId: String
    ) async {
        guard let client else { return }
        let day = Calendar.current.startOfDay(for: service.date)
        let row = [
            TeamSheet.dateFormatter.string(from: service.date),
            role,
            email,
            name,
            status.rawValue,
            ISO8601DateFormatter().string(from: Date())
        ]

        do {
            isReadOnly = false
            let existing = mySignup(for: service, role: role, email: email)
            var writtenRow = existing?.row

            // Row 1 is the header, so anything below 2 is not a real row to
            // rewrite — append and learn where it went.
            if let target = existing?.row, target >= 2 {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.signupsTab)!A\(target):F\(target)",
                    row: row
                )
            } else {
                writtenRow = try await client.append(
                    sheetId: sheetId, tab: TeamSheet.signupsTab, row: row
                )
            }

            // Reflect it immediately; the sheet is the truth but a reload is
            // four round trips and this is one tap.
            var list = signups[day] ?? []
            list.removeAll { $0.role == role && $0.email.caseInsensitiveCompare(email) == .orderedSame }
            list.append(TeamSignup(role: role, email: email, name: name,
                                   statusRaw: status.rawValue, row: writtenRow))
            signups[day] = list
        } catch SheetsClient.SheetsError.http(403, _) {
            // Reads work, so this is not the scope and not the sheet being
            // missing: this account has view access where it needs edit.
            isReadOnly = true
            errorMessage = "이 시트에 편집 권한이 없어 사인업을 저장하지 못했습니다. 시트 주인에게 이 계정을 편집자로 추가해 달라고 요청하세요."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Pushing a 콘티 into the sheet

    struct PushResult {
        let written: Int
        let replaced: Int
    }

    /// Writes a playlist into the Songs tab as this service's 콘티.
    ///
    /// The point of the bridge: the playlist already holds the order and the
    /// links, and the app already knows the key from any chart the team has
    /// made — so the leader should not be retyping all three into a
    /// spreadsheet.
    ///
    /// Existing rows for the date are rewritten in place rather than
    /// appended to. Appending would leave last week's attempt underneath the
    /// new one, and the sheet is what the team reads on Sunday morning.
    func pushSongs(
        _ incoming: [TeamSong],
        to service: TeamService,
        sheetId: String,
        existingRows: [[String]]
    ) async throws -> PushResult {
        guard let client else { throw SheetsClient.SheetsError.noSheet }
        let day = TeamSheet.dateFormatter.string(from: service.date)

        // 1-based sheet rows already holding this date.
        var targets: [Int] = []
        for (offset, row) in existingRows.enumerated() where offset > 0 {
            guard row.count > TeamSheet.Songs.date,
                  let date = TeamSheet.day(row[TeamSheet.Songs.date]),
                  Calendar.current.isDate(date, inSameDayAs: service.date) else { continue }
            targets.append(offset + 1)
        }

        func cells(_ song: TeamSong) -> [String] {
            [
                day,
                String(song.order),
                song.title,
                song.url?.absoluteString ?? "",
                song.key ?? "",
                song.transpose == 0 ? "" : String(song.transpose),
                song.notes ?? ""
            ]
        }

        var updates: [(range: String, rows: [[String]])] = []
        for (index, song) in incoming.enumerated() where index < targets.count {
            let row = targets[index]
            updates.append(("\(TeamSheet.songsTab)!A\(row):G\(row)", [cells(song)]))
        }
        // Rows the old 콘티 used and the new one does not: blanked, not left
        // behind claiming to be part of this Sunday.
        for row in targets.dropFirst(incoming.count) {
            updates.append(("\(TeamSheet.songsTab)!A\(row):G\(row)",
                            [Array(repeating: "", count: 7)]))
        }
        if !updates.isEmpty {
            try await client.batchWrite(sheetId: sheetId, updates: updates)
        }

        // Anything beyond the rows that existed has to be appended.
        for song in incoming.dropFirst(targets.count) {
            try await client.append(sheetId: sheetId, tab: TeamSheet.songsTab, row: cells(song))
        }

        songs[Calendar.current.startOfDay(for: service.date)] = incoming
        return PushResult(written: incoming.count, replaced: targets.count)
    }

    /// The Songs tab exactly as it stands, so a push knows which rows to
    /// rewrite rather than guessing from the parsed view.
    func rawSongRows(sheetId: String) async throws -> [[String]] {
        guard let client else { throw SheetsClient.SheetsError.noSheet }
        return try await client.read(sheetId: sheetId, range: TeamSheet.songsTab)
    }

    // MARK: - Parsing

    static func parseRoles(_ rows: [[String]]) -> [TeamRole] {
        rows.dropFirst().compactMap { row in
            guard row.count > TeamSheet.Roles.name else { return nil }
            let name = row[TeamSheet.Roles.name].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let active = row.count > TeamSheet.Roles.active
                ? row[TeamSheet.Roles.active].lowercased() : "true"
            guard !["false", "no", "n", "0"].contains(active) else { return nil }
            let order = row.count > TeamSheet.Roles.order
                ? Double(row[TeamSheet.Roles.order]) ?? 0 : 0
            return TeamRole(name: name, order: order)
        }
        .sorted { $0.order < $1.order }
    }

    static func parseSchedule(_ rows: [[String]], roles: [TeamRole]) -> [TeamService] {
        guard let header = rows.first else { return [] }
        // Role columns are whatever the leader put after the fixed three, so
        // read their names from the header rather than assuming the Roles tab
        // and the Schedule tab agree.
        let roleColumns = header.enumerated()
            .filter { $0.offset >= TeamSheet.Schedule.fixedColumns }
            .map { ($0.offset, $0.element.trimmingCharacters(in: .whitespaces)) }

        return rows.dropFirst().compactMap { row in
            guard row.count > TeamSheet.Schedule.date,
                  let date = TeamSheet.day(row[TeamSheet.Schedule.date]) else { return nil }
            var assignments: [String: String] = [:]
            for (index, name) in roleColumns where row.count > index {
                let who = row[index].trimmingCharacters(in: .whitespaces)
                if !who.isEmpty, !name.isEmpty { assignments[name] = who }
            }
            let title = row.count > TeamSheet.Schedule.title
                ? row[TeamSheet.Schedule.title] : ""
            let notes = row.count > TeamSheet.Schedule.notes
                ? row[TeamSheet.Schedule.notes] : ""
            return TeamService(
                date: date,
                title: title.isEmpty ? "주일예배" : title,
                notes: notes.isEmpty ? nil : notes,
                assignments: assignments
            )
        }
        .sorted { $0.date < $1.date }
    }

    static func parseSongs(_ rows: [[String]]) -> [Date: [TeamSong]] {
        var out: [Date: [TeamSong]] = [:]
        for row in rows.dropFirst() {
            guard row.count > TeamSheet.Songs.title,
                  let date = TeamSheet.day(row[TeamSheet.Songs.date]) else { continue }
            let title = row[TeamSheet.Songs.title].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            func cell(_ i: Int) -> String? {
                guard row.count > i else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            out[Calendar.current.startOfDay(for: date), default: []].append(
                TeamSong(
                    order: Int(cell(TeamSheet.Songs.order) ?? "") ?? 0,
                    title: title,
                    url: cell(TeamSheet.Songs.url).flatMap(URL.init(string:)),
                    key: cell(TeamSheet.Songs.key),
                    transpose: Int(cell(TeamSheet.Songs.transpose) ?? "") ?? 0,
                    notes: cell(TeamSheet.Songs.notes)
                )
            )
        }
        return out
    }

    // MARK: - Roster

    /// Everyone on the Members tab, with their row so a change rewrites.
    struct Member: Identifiable, Hashable {
        let email: String
        let name: String
        let isActive: Bool
        let row: Int
        var id: String { email.lowercased() }
    }

    @Published private(set) var members: [Member] = []

    func addMember(email: String, name: String, sheetId: String) async {
        guard let client else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@") else {
            errorMessage = "이메일 주소가 아닙니다."
            return
        }
        guard !members.contains(where: { $0.email.lowercased() == address }) else {
            errorMessage = "이미 명단에 있습니다."
            return
        }
        do {
            let row = try await client.append(
                sheetId: sheetId, tab: TeamSheet.membersTab,
                row: [address, name, "TRUE"]
            )
            members.append(Member(email: address, name: name, isActive: true, row: row ?? 0))
            memberEmails.insert(address)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Deactivates rather than deletes.
    ///
    /// Removing the row would also remove the record that this person was
    /// ever on the team, and their signups would then point at nobody. A
    /// FALSE keeps the history and is reversible by the leader in one cell.
    func setMemberActive(_ active: Bool, member: Member, sheetId: String) async {
        guard let client, member.row >= 2 else { return }
        do {
            try await client.write(
                sheetId: sheetId,
                range: "\(TeamSheet.membersTab)!A\(member.row):C\(member.row)",
                row: [member.email, member.name, active ? "TRUE" : "FALSE"]
            )
            members = members.map {
                $0.id == member.id
                    ? Member(email: $0.email, name: $0.name, isActive: active, row: $0.row)
                    : $0
            }
            if active { memberEmails.insert(member.email.lowercased()) }
            else { memberEmails.remove(member.email.lowercased()) }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Live

    /// Reads only the Live tab — one request, so it can run on a short timer
    /// without costing what a full reload would.
    func pollLive(sheetId: String) async {
        guard let client,
              let rows = try? await client.read(sheetId: sheetId, range: TeamSheet.liveTab)
        else { return }

        var order: [Date: Int] = [:]
        var by: [Date: String] = [:]
        var at: [Date: Int] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > TeamSheet.Live.order,
                  let date = TeamSheet.day(row[TeamSheet.Live.date]),
                  let value = Int(row[TeamSheet.Live.order].filter(\.isNumber))
            else { continue }
            let day = Calendar.current.startOfDay(for: date)
            order[day] = value
            at[day] = offset + 1
            if row.count > TeamSheet.Live.by { by[day] = row[TeamSheet.Live.by] }
        }
        liveOrder = order
        liveUpdatedBy = by
        liveRows = at
    }

    /// Moves the service to an item, for everyone.
    func setLive(order: Int, service: TeamService, by name: String, sheetId: String) async {
        guard let client else { return }
        let day = Calendar.current.startOfDay(for: service.date)
        // Optimistic: the person tapping should not wait on a round trip to
        // see the thing they just did.
        liveOrder[day] = order
        liveUpdatedBy[day] = name

        let row = [
            TeamSheet.dateFormatter.string(from: service.date),
            String(order),
            ISO8601DateFormatter().string(from: Date()),
            name
        ]
        do {
            if let existing = liveRows[day], existing >= 2 {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.liveTab)!A\(existing):D\(existing)",
                    row: row
                )
            } else {
                liveRows[day] = try await client.append(
                    sheetId: sheetId, tab: TeamSheet.liveTab, row: row
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func parsePlan(_ rows: [[String]]) -> [Date: [PlanItem]] {
        var out: [Date: [PlanItem]] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > TeamSheet.Plan.title,
                  let date = TeamSheet.day(row[TeamSheet.Plan.date]) else { continue }
            func cell(_ i: Int) -> String? {
                guard row.count > i else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let title = cell(TeamSheet.Plan.title) else { continue }
            out[Calendar.current.startOfDay(for: date), default: []].append(
                PlanItem(
                    order: Int(cell(TeamSheet.Plan.order) ?? "") ?? 0,
                    kind: PlanItem.Kind(raw: cell(TeamSheet.Plan.type) ?? ""),
                    title: title,
                    minutes: cell(TeamSheet.Plan.minutes).flatMap { Int($0.filter(\.isNumber)) },
                    person: cell(TeamSheet.Plan.person),
                    key: cell(TeamSheet.Plan.key),
                    url: cell(TeamSheet.Plan.url).flatMap(URL.init(string:)),
                    notes: cell(TeamSheet.Plan.notes),
                    row: offset + 1
                )
            )
        }
        return out
    }

    static func parseSignups(_ rows: [[String]]) -> [Date: [TeamSignup]] {
        var out: [Date: [TeamSignup]] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > TeamSheet.Signups.email,
                  let date = TeamSheet.day(row[TeamSheet.Signups.date]) else { continue }
            let status = row.count > TeamSheet.Signups.status
                ? row[TeamSheet.Signups.status].lowercased() : "available"
            out[Calendar.current.startOfDay(for: date), default: []].append(
                TeamSignup(
                    role: row[TeamSheet.Signups.role],
                    email: row[TeamSheet.Signups.email],
                    name: row.count > TeamSheet.Signups.name ? row[TeamSheet.Signups.name] : "",
                    statusRaw: status,
                    row: offset + 1
                )
            )
        }
        return out
    }
}
