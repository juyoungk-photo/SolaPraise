//
//  SheetMusicSources.swift
//  SolaPraise
//
//  Where a song's official 악보 actually lives.
//
//  WHY THIS EXISTS: WorshipSetParser can only find links a channel publishes
//  in its own description, and most worship uploads have none — the 어노인팅
//  tracks in a 콘티 come from auto-generated "- Topic" channels with no
//  description at all. So the app knew about official charts in principle and
//  showed them almost never.
//
//  A detected chart is a guess at something that, for most published worship
//  songs, already exists definitively and is sold by the team that wrote it.
//  Pointing at that is better behaviour than competing with it, and it is
//  ministry income for the people whose song it is.
//
//  These are searches, not scrapes. The app opens a query and the shop serves
//  its own page.
//

import Foundation

enum SheetMusicSources {

    struct Source: Identifiable, Hashable {
        let name: String
        let detail: String
        let domain: String?
        /// The store's own search page, with {q} for the query, when it has
        /// one that takes a query in the URL — better than a web search
        /// scoped to it, which only finds what a search engine indexed.
        var searchPage: String? = nil
        var id: String { name }

        /// A site-scoped search rather than each shop's own query format,
        /// which differ and change. This keeps working when they redesign.
        func url(for title: String) -> URL? {
            let cleaned = SheetMusicSources.clean(title)
            let query: String
            if let domain {
                query = "\(cleaned) 악보 site:\(domain)"
            } else {
                query = "\(cleaned) 악보"
            }
            guard let encoded = query.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) else { return nil }
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        }
    }

    // MARK: - Per song

    /// A worship team that sells its own charts, and how to tell its songs.
    struct Publisher {
        let name: String
        let store: Source
        /// Lowercased fragments of a channel name or title that mean this team.
        let marks: [String]
    }

    /// Teams whose official store is known. Only these: a store guessed for
    /// a team that does not sell charts there is a dead end.
    static let publishers: [Publisher] = [
        Publisher(name: "어노인팅",
                  store: Source(name: "어노인팅 온라인샵", detail: "어노인팅 공식 악보",
                                domain: "anointingmusic.com"),
                  marks: ["anointing", "어노인팅"]),
        Publisher(name: "마커스",
                  store: Source(name: "마커스 스토어", detail: "MARKERS 공식 악보",
                                domain: "markersworship.com"),
                  marks: ["markers", "마커스"])
    ]

    /// The large catalogues — licensed charts for most worship songs in
    /// use, searched by their own search pages. SongSelect is CCLI's, which
    /// a church holding a CCLI license may print from.
    static let stores: [Source] = [
        Source(name: "SongSelect (CCLI)", detail: "교회 라이선스로 출력 가능한 공식 악보",
               domain: "songselect.ccli.com",
               searchPage: "https://songselect.ccli.com/search/results?search={q}"),
        Source(name: "PraiseCharts", detail: "영어 찬양 공식 악보",
               domain: "praisecharts.com",
               searchPage: "https://www.praisecharts.com/search?q={q}")
    ]

    /// Sheet-music sites that carry many teams' charts.
    static let shops: [Source] = [
        Source(name: "악보통", detail: "한국 CCM 악보", domain: "akbotong.com"),
        Source(name: "마피아니스트", detail: "파트별 악보", domain: "mapianist.com"),
        Source(name: "악보바다", detail: "찬양 악보", domain: "akbobada.com")
    ]

    /// The team a song is from, by its channel or its title.
    static func publisher(channel: String?, title: String) -> Publisher? {
        let text = ((channel ?? "") + " " + title).lowercased()
        return publishers.first { publisher in publisher.marks.contains { text.contains($0) } }
    }

    /// What one song's 악보 menu offers, best first.
    ///
    /// Per song rather than one list for every song: an 어노인팅 song was
    /// offered the 마커스 store, and every search was the bare title. Now
    /// the team's own store comes first — and only that team's — and the
    /// searches carry what makes them find THIS song: the cleaned title
    /// plus the team, or the hymn number for a 찬송가.
    struct Plan {
        let song: String
        /// The English title an upload carries beside the Korean one —
        /// 「No Turning Back」 — which the English catalogues index.
        var english: String? = nil
        let publisher: Publisher?
        let hymn: Int?

        /// Words added to every search after the title.
        var context: String {
            if let hymn { return "새찬송가 \(hymn)장" }
            return publisher?.name ?? ""
        }

        /// The open web, with the song's details: 「악보 검색」.
        var searchURL: URL? { search("\(song) \(context) 악보", domain: nil) }

        func url(for source: Source) -> URL? {
            if let page = source.searchPage {
                let query = english ?? song
                guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                else { return nil }
                return URL(string: page.replacingOccurrences(of: "{q}", with: encoded))
            }
            return search("\(song) \(context) 악보", domain: source.domain)
        }

        private func search(_ text: String, domain: String?) -> URL? {
            let query = (domain.map { "\(text) site:\($0)" } ?? text)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else { return nil }
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        }
    }

    static func plan(title: String, channel: String?) -> Plan {
        let song = SongSearchSuggestions.songTitles(title: title, description: "", channel: channel).first
            ?? clean(title)
        return Plan(song: song,
                    english: englishTitle(in: title),
                    publisher: publisher(channel: channel, title: title),
                    hymn: SongSearchSuggestions.hymnNumber(in: title))
    }

    /// The English title beside a Korean one: the Latin words that follow
    /// the Korean in a part of the title — 「주님 뜻대로 살기로 했네 No
    /// Turning Back」, 「주님께 영광 높이 드리세 / GLORY TO THE LORD MOST
    /// HIGH」 — and never the team or the format ("Live Clip").
    static func englishTitle(in title: String) -> String? {
        let parts = SongSearchSuggestions.parts(of: title.precomposedStringWithCompatibilityMapping)
        for (index, part) in parts.enumerated() {
            let latin: String?
            if let range = part.range(of: #"(?<=\p{Hangul})[\s(]+([A-Za-z][A-Za-z ,'’!?.&]{3,})\)?$"#,
                                      options: .regularExpression) {
                latin = String(part[range]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            } else if index > 0, part.range(of: #"^[A-Za-z][A-Za-z ,'’!?.&]{3,}$"#, options: .regularExpression) != nil,
                      parts[index - 1].range(of: #"\p{Hangul}"#, options: .regularExpression) != nil {
                latin = part
            } else {
                latin = nil
            }
            guard let candidate = latin?.trimmingCharacters(in: .whitespaces),
                  candidate.split(separator: " ").count >= 2,
                  !SongSearchSuggestions.isPackaging(candidate, team: []) else { continue }
            let lower = candidate.lowercased()
            if ["live clip", "live", "official", "acoustic"].contains(where: { lower == $0 || lower.hasSuffix(" " + $0) }) { continue }
            return candidate
        }
        return nil
    }

    /// Strips the decoration channels put around a song name, so the search
    /// is the title and not the uploader's formatting.
    static func clean(_ title: String) -> String {
        var text = title
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "【[^】]*】"] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: .regularExpression
            )
        }
        // Everything after a vertical bar is nearly always credits.
        if let bar = text.firstIndex(where: { $0 == "|" || $0 == "ㅣ" }) {
            text = String(text[..<bar])
        }
        text = text.replacingOccurrences(
            of: "\\b(live|lyrics?|official|mv|worship|cover|ver\\.?)\\b",
            with: " ", options: [.regularExpression, .caseInsensitive]
        )
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
