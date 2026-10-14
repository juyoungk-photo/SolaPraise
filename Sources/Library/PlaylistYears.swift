//
//  PlaylistYears.swift
//  SolaPraise
//
//  The years a channel's playlists fall in, for the chips over them.
//
//  WHY: a church channel files its services one playlist each, and adds a
//  playlist per year — 「2026」 — holding the same services again. Shown as
//  cards those year playlists read as one more service among dozens; what
//  they really are is a way to find a year. So a year becomes a chip, and a
//  chip shows every playlist of that year, whether or not the church's
//  「2026」 playlist happens to hold it.
//
//  A playlist's year is the one in its title (「2025 성탄 예배」), else the
//  year it was made. Foundation only, so Tools/check-playlist-years.swift
//  runs it.
//

import Foundation

enum PlaylistYears {

    /// A title that is nothing but a year: 「2026」, 「2026년」.
    static func yearOnly(_ title: String) -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstYear(in: trimmed, pattern: #"^(20\d{2})\s*년?$"#)
    }

    /// The year written in a title, read only where it stands as a number
    /// of its own — not 「32025」, not inside 「20250105」.
    static func yearInTitle(_ title: String) -> Int? {
        firstYear(in: title, pattern: #"(?<![0-9])(20\d{2})(?![0-9])"#)
    }

    private static func firstYear(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    static func year(title: String, publishedAt: Date?, calendar: Calendar = .current) -> Int? {
        if let year = yearInTitle(title) { return year }
        return publishedAt.map { calendar.component(.year, from: $0) }
    }

    /// Chips, newest first: only when the playlists span two years or more,
    /// or the channel keeps a playlist named for a year.
    static func chips(_ playlists: [(title: String, publishedAt: Date?)], calendar: Calendar = .current) -> [Int] {
        let years = Set(playlists.compactMap { year(title: $0.title, publishedAt: $0.publishedAt, calendar: calendar) })
        let named = playlists.contains { yearOnly($0.title) != nil }
        guard years.count >= 2 || named else { return [] }
        return years.sorted(by: >)
    }
}
