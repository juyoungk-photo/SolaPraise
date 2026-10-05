//
//  ServiceArchive.swift
//  SolaPraise
//
//  Keeping what the team actually sang.
//
//  A 콘티 is written for one Sunday and then overwritten by the next one. The
//  songs themselves are the lasting part — what the team knows, what it has
//  sung recently, what to avoid repeating next month — and until now that
//  record only existed in a spreadsheet column that gets replaced every week.
//
//  So a finished service's songs go into one standing playlist. Not a
//  playlist per service: nobody opens fifty playlists of four songs. One
//  list, newest at the end, which is a set list history you can scroll.
//
//  Additive and idempotent. Archiving the same service twice adds nothing
//  the second time, because the run is a tap and taps get repeated.
//

import Foundation

@MainActor
final class ServiceArchive: ObservableObject {

    /// The one list. Matched by title, created if it is not there — a team
    /// should not have to make it by hand on every member's account.
    static let playlistTitle = "CCC_예배찬양곡_모음"

    struct Song: Hashable {
        let videoId: String
        let title: String
    }

    struct Outcome {
        let added: Int
        let alreadyThere: Int
        let playlistId: String
        var isNothingNew: Bool { added == 0 && alreadyThere > 0 }
    }

    @Published private(set) var isWorking = false
    @Published var note: String?

    /// Services already filed, by date.
    ///
    /// Content-level dedupe alone is not enough to stop a second run: it
    /// stops duplicate VIDEOS, but it still spends a read and a round trip
    /// per song to discover there is nothing to do, and it leaves the button
    /// looking like it was never pressed. Remembering the service makes the
    /// screen say so, and makes the second press free.
    @Published private(set) var archivedDays: Set<Date> = ServiceArchive.loadArchived()

    private static let archivedKey = "team.archivedServiceDays"

    private static func loadArchived() -> Set<Date> {
        let stamps = UserDefaults.standard.array(forKey: archivedKey) as? [Double] ?? []
        return Set(stamps.map { Date(timeIntervalSince1970: $0) })
    }

    private func persistArchived() {
        UserDefaults.standard.set(
            archivedDays.map(\.timeIntervalSince1970),
            forKey: Self.archivedKey
        )
    }

    static func day(of service: TeamService) -> Date {
        Calendar.current.startOfDay(for: service.date)
    }

    /// Forgets which services have been filed, so they can be filed again.
    /// The playlist itself is untouched — this is the app's memory, not the
    /// archive, and the content dedupe still stops repeats.
    func forgetAll() {
        archivedDays = []
        persistArchived()
        note = nil
    }

    func hasArchived(_ service: TeamService) -> Bool {
        archivedDays.contains(Self.day(of: service))
    }

    func archive(_ songs: [Song],
                 of service: TeamService,
                 using client: YouTubeAPIClient) async -> Outcome? {
        let wanted = songs.reduce(into: [Song]()) { list, song in
            // The same song twice in one service — a reprise — is one entry.
            if !list.contains(where: { $0.videoId == song.videoId }) { list.append(song) }
        }
        guard !wanted.isEmpty else {
            note = "보관할 찬양이 없습니다. 순서에 영상이 연결된 곡이 있어야 합니다."
            return nil
        }

        isWorking = true
        note = nil
        defer { isWorking = false }

        do {
            let playlistId = try await findOrCreate(using: client)

            // Full pagination, not a bounded read: this list grows by a few
            // songs a week for years, and a partial read would start adding
            // duplicates the moment it outgrew the window.
            let existing = try await client.playlistItems(playlistId: playlistId)
            let have = Set(existing.compactMap(\.videoId))

            var added = 0
            for song in wanted where !have.contains(song.videoId) {
                try await client.addVideo(song.videoId, to: playlistId)
                added += 1
            }
            let outcome = Outcome(
                added: added,
                alreadyThere: wanted.count - added,
                playlistId: playlistId
            )
            archivedDays.insert(Self.day(of: service))
            persistArchived()
            note = describe(outcome)
            return outcome
        } catch {
            note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private func findOrCreate(using client: YouTubeAPIClient) async throws -> String {
        let mine = try await client.myPlaylists()
        let target = Self.playlistTitle.trimmingCharacters(in: .whitespaces)
        if let found = mine.first(where: {
            $0.title.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(target) == .orderedSame
        }) {
            return found.id
        }
        // Unlisted, not private: the team shares one link to it. Private
        // would mean the list exists and nobody but its creator can open it.
        let created = try await client.createPlaylist(
            title: Self.playlistTitle,
            description: "예배에서 부른 찬양 모음. SolaPraise가 예배가 끝난 뒤 채웁니다.",
            privacy: "unlisted"
        )
        return created.id
    }

    private func describe(_ outcome: Outcome) -> String {
        if outcome.added == 0 {
            return "이미 모두 보관되어 있습니다."
        }
        if outcome.alreadyThere == 0 {
            return "\(outcome.added)곡을 「\(Self.playlistTitle)」에 보관했습니다."
        }
        return "\(outcome.added)곡 보관, \(outcome.alreadyThere)곡은 이미 있었습니다."
    }
}
