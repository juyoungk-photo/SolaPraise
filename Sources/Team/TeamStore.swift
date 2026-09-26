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

struct TeamSignup: Identifiable, Hashable {
    let role: String
    let email: String
    let name: String
    let isAvailable: Bool
    /// 1-based row on the Signups tab, so an update rewrites in place rather
    /// than appending a second opinion.
    let row: Int
    var id: String { "\(role)|\(email)" }
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

    func songs(for service: TeamService) -> [TeamSong] {
        (songs[Calendar.current.startOfDay(for: service.date)] ?? [])
            .sorted { $0.order < $1.order }
    }

    func signups(for service: TeamService, role: String) -> [TeamSignup] {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .filter { $0.role == role && $0.isAvailable }
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

            roles = Self.parseRoles(roleData)
            services = Self.parseSchedule(schedule, roles: roles)
            songs = Self.parseSongs(songData)
            signups = Self.parseSignups(signupData)
            memberEmails = await loadMembers(sheetId: sheetId, client: client)
            lastLoaded = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Members tab is optional. Without one, anyone who can open the
    /// sheet counts as a member — which is the same thing, since Google's own
    /// sharing is what actually protects it.
    private func loadMembers(sheetId: String, client: SheetsClient) async -> Set<String> {
        guard let rows = try? await client.read(sheetId: sheetId, range: TeamSheet.membersTab),
              rows.count > 1 else { return [] }
        var emails: Set<String> = []
        for row in rows.dropFirst() {
            guard row.count > TeamSheet.Members.email else { continue }
            let email = row[TeamSheet.Members.email].trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else { continue }
            let active = row.count > TeamSheet.Members.active
                ? row[TeamSheet.Members.active].lowercased()
                : "true"
            guard !["false", "no", "n", "0"].contains(active) else { continue }
            emails.insert(email.lowercased())
        }
        return emails
    }

    // MARK: - Signing up

    /// Records availability, rewriting the member's existing row when they
    /// already answered — otherwise saying yes then no would leave both.
    func setAvailability(
        _ available: Bool,
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
            available ? "available" : "declined",
            ISO8601DateFormatter().string(from: Date())
        ]

        do {
            isReadOnly = false
            if let existing = mySignup(for: service, role: role, email: email) {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.signupsTab)!A\(existing.row):F\(existing.row)",
                    row: row
                )
            } else {
                try await client.append(sheetId: sheetId, tab: TeamSheet.signupsTab, row: row)
            }
            // Reflect it immediately; the sheet is the truth but a reload is
            // four round trips and this is one tap.
            var list = signups[day] ?? []
            list.removeAll { $0.role == role && $0.email.caseInsensitiveCompare(email) == .orderedSame }
            list.append(TeamSignup(role: role, email: email, name: name,
                                   isAvailable: available,
                                   row: mySignup(for: service, role: role, email: email)?.row ?? 0))
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
                    isAvailable: status != "declined",
                    row: offset + 1
                )
            )
        }
        return out
    }
}
