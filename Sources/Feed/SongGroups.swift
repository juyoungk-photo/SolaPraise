//
//  SongGroups.swift
//  SolaPraise
//
//  Search results gathered by song: one row per song, its other uploads
//  folded under it — to compare versions rather than scroll past them.
//
//  WHY: a search for one song returns it fifteen times — the official
//  video, three live sets, a lyric video, a piano cover, the same upload
//  re-posted — between two or three other songs. Choosing the version to
//  play or put in a 콘티 meant reading every title to see which were the
//  same song. Grouped, the songs are the list and the versions are a tap
//  away, side by side with their channel, length and views.
//
//  Foundation only: Tools/check-song-groups.swift runs it.
//

import Foundation

enum SongGroups {

    struct Group<Item> {
        /// The song, as read out of its first upload's title.
        let song: String
        /// Its uploads, in the order given — the search's own order of
        /// relevance, so the first is the one YouTube ranked highest.
        var items: [Item]
    }

    /// `items` by the song each is of, each song where it first appears.
    static func group<Item>(_ items: [Item], title: (Item) -> String,
                            channel: (Item) -> String? = { _ in nil }) -> [Group<Item>] {
        var groups: [Group<Item>] = []
        var keys: [Key] = []
        for item in items {
            let parts = PlanSongTitle.split(title(item), channel: channel(item))
            let key = Key(parts)
            if let index = keys.firstIndex(where: { $0.isSameSong(as: key) }) {
                groups[index].items.append(item)
            } else {
                groups.append(Group(song: parts.title, items: [item]))
                keys.append(key)
            }
        }
        return groups
    }

    /// What decides that two uploads are one song.
    private struct Key {
        let title: String
        let normalised: String
        let hymn: Int?
        let isMedley: Bool

        init(_ parts: PlanSongTitle.Parts) {
            title = parts.title
            normalised = SongSearchSuggestions.normalised(parts.title)
            hymn = parts.hymn
            isMedley = parts.title.contains(" + ")
        }

        func isSameSong(as other: Key) -> Bool {
            if PlanSongTitle.sameSong(title, other.title) { return true }
            // A medley is only ever itself: 「A + B」 begins with A.
            guard !isMedley, !other.isMedley else { return false }
            // One hymn under its old and new wording: 546장 is 546장.
            if let hymn, let theirs = other.hymn { return hymn == theirs }
            // 「곡」 and 「곡 English Title」: the English name after the
            // Korean is the same song, read as part of its title.
            let (short, long) = normalised.count <= other.normalised.count
                ? (normalised, other.normalised) : (other.normalised, normalised)
            return short.count >= 6 && long.hasPrefix(short)
        }
    }
}
