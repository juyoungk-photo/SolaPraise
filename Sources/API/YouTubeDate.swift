//
//  YouTubeDate.swift
//  SolaPraise
//
//  A date as YouTube's API writes it: 「2024-07-14T09:30:00Z」, sometimes
//  with fractions of a second, 「2024-07-14T09:30:00.123Z」.
//
//  WHY ITS OWN: read with ISO8601FormatStyle — a value, safe on any thread
//  and cheap. An ISO8601DateFormatter was built for every date (shared,
//  formatters raced between two screens decoding at once), and that was a
//  tenth of decoding a feed. A wrong reading would only show as videos
//  sorted oddly, so Tools/check-youtube-date.swift runs it.
//

import Foundation

enum YouTubeDate {
    static func parse(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle())
    }
}
