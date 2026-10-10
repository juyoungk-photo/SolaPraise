//
//  DailySeries.swift
//  SolaPraise
//
//  Daily episodes — 모닝워십, 매일성경 QT — played one after another, the
//  day before or the day after.
//
//  WHY: these are listened to as a run. Having finished today's, the next
//  thing wanted is yesterday's, or — catching up — the next day's; and the
//  queue the 말씀 tab built was "the four newest on this channel", which is
//  neither. An episode belongs to a series when its title carries a date and
//  the series' mark: a leading 「[모닝워십]」, or a known daily name.
//
//  Pure, so it is checked without the app (Tools/check-daily-series.swift).
//

import Foundation

enum DailySeries {

    enum Direction: String, CaseIterable {
        case off, previous, next
    }

    /// What marks a title as one series: its leading bracket — 「[모닝워십]」
    /// — or a daily name it carries. Nil when the title names none.
    static func key(of title: String) -> String? {
        if let range = title.range(of: #"^\s*[\[【]([^\]】]{2,20})[\]】]"#, options: .regularExpression) {
            return title[range].trimmingCharacters(in: CharacterSet(charactersIn: " []【】"))
        }
        let names = ["매일성경", "모닝워십", "새벽예배", "새벽기도", "QT", "큐티", "생명의 삶", "오늘의 양식"]
        return names.first { title.localizedCaseInsensitiveContains($0) }
    }

    /// The episodes of `current`'s series among `videos`, in the order of
    /// listening: oldest first for `.next`, newest first for `.previous` —
    /// and where `current` sits in that order. Nil when the title is not a
    /// dated episode of a series, or it has no other episodes here.
    static func queue<V>(for current: V, among videos: [V], direction: Direction,
                         title: (V) -> String, channel: (V) -> String?, id: (V) -> String,
                         now: Date = Date()) -> (videos: [V], start: Int)? {
        guard direction != .off,
              let key = key(of: title(current)),
              EpisodeDate.inTitle(title(current), now: now) != nil else { return nil }
        let currentChannel = channel(current)
        var seen = Set<String>()
        let episodes = videos.compactMap { video -> (V, Date)? in
            guard channel(video) == currentChannel, self.key(of: title(video)) == key,
                  let date = EpisodeDate.inTitle(title(video), now: now),
                  seen.insert(id(video)).inserted else { return nil }
            return (video, date)
        }
        guard episodes.count > 1 else { return nil }
        let ordered = episodes.sorted { a, b in
            direction == .next ? a.1 < b.1 : a.1 > b.1
        }.map(\.0)
        guard let start = ordered.firstIndex(where: { id($0) == id(current) }) else { return nil }
        return (ordered, start)
    }
}
