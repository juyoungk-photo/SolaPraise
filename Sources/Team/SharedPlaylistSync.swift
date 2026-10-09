//
//  SharedPlaylistSync.swift
//  SolaPraise
//
//  Putting the team's service playlists on everybody's 홈 and 찬양 tab.
//
//  One person builds Sunday's 콘티 and writes it to the Schedule tab's
//  재생목록 column. This is the other half: every other member's app reads
//  that column and makes the playlist reachable without anyone pasting a
//  link into a group chat.
//
//  ADDED ONCE, NOT ENFORCED. A playlist that reappeared every launch because
//  the sheet still names it would be an app arguing with its user, and the
//  home screen is explicitly the one place where everything was put there
//  deliberately. So each playlist id is remembered the first time it is
//  offered: remove the card and it stays removed.
//

import Foundation
import SwiftData

@MainActor
enum SharedPlaylistSync {

    /// Playlists already offered on this device, by id. Kept out of SwiftData
    /// on purpose — it is a record of what this device has been shown, not
    /// content, and it has to survive the card being deleted.
    private static let seenKey = "team.sharedPlaylistsSeen"

    private static var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: seenKey) }
    }

    /// Adds a 찬양 pin and a home card for any service playlist this device
    /// has not been offered before.
    ///
    /// Only services from the recent past onwards. A year of Sundays would
    /// otherwise arrive as a year of cards the first time somebody opened
    /// the app, which is not a feature, it is a flood.
    static func run(
        services: [(service: TeamService, playlistId: String)],
        context: ModelContext
    ) {
        let horizon = Calendar.current.date(byAdding: .day, value: -21, to: Date())
            ?? Date.distantPast
        var offered = seen

        for entry in services where entry.service.date >= horizon {
            let id = entry.playlistId
            guard !offered.contains(id) else { continue }
            offered.insert(id)

            let title = name(for: entry.service)
            pinPlaylist(id: id, title: title, context: context)
            addHomeCard(id: id, title: title, context: context)
        }

        guard offered != seen else { return }
        seen = offered
        try? context.save()
    }

    /// "10/11 주일 2부예배" — the service, not the playlist's own name, which
    /// on YouTube is whatever the person who made it typed.
    private static func name(for service: TeamService) -> String {
        let day = service.date.formatted(.dateTime.month(.defaultDigits).day())
        return "\(day) \(service.title)"
    }

    private static func pinPlaylist(id: String, title: String, context: ModelContext) {
        let existing = try? context.fetch(
            FetchDescriptor<CachedPlaylist>(
                predicate: #Predicate { $0.playlistId == id }
            )
        )
        if let found = existing?.first {
            // Already known — make sure it is pinned and filed under 찬양,
            // which is what puts it at the top of that tab.
            found.isPinned = true
            found.purposeRaw = Purpose.worship.rawValue
            return
        }
        context.insert(CachedPlaylist(
            playlistId: id,
            channelId: "",
            title: title,
            purpose: .worship,
            isPinned: true
        ))
    }

    private static func addHomeCard(id: String, title: String, context: ModelContext) {
        let existing = try? context.fetch(
            FetchDescriptor<HomeCard>(
                predicate: #Predicate { $0.targetId == id }
            )
        )
        guard existing?.isEmpty ?? true else { return }

        let order = (try? context.fetch(FetchDescriptor<HomeCard>()))?
            .map(\.sortOrder).max() ?? 0
        context.insert(HomeCard(
            kind: .playlist,
            targetId: id,
            title: title,
            sortOrder: order + 1
        ))
    }
}
