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

    /// Ordered by how likely they are to have the official chart rather than
    /// somebody's transcription of it.
    static let all: [Source] = [
        Source(name: "어노인팅 온라인샵", detail: "어노인팅 공식 악보",
               domain: "anointingmusic.com"),
        Source(name: "마커스 스토어", detail: "MARKERS 공식 악보",
               domain: "markersworship.com"),
        Source(name: "악보통", detail: "한국 CCM 악보", domain: "akbotong.com"),
        Source(name: "마피아니스트", detail: "파트별 악보", domain: "mapianist.com"),
        Source(name: "악보바다", detail: "찬양 악보", domain: "akbobada.com"),
        Source(name: "전체 검색", detail: "웹 전체에서 악보 찾기", domain: nil)
    ]

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
