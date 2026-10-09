//
//  AudioSources.swift
//  SolaPraise
//
//  Where to get the recording itself.
//
//  WHY THIS MATTERS MORE THAN THE CHART: everything the analyser does needs
//  audio, and the one source the app can never use is the one it is playing.
//  YouTube's terms forbid taking the audio out of the player, which leaves
//  exactly two honest ways to get a file: own it, or capture a performance
//  through an input. This covers the first.
//
//  A bought track is also the best input the detector will ever get — full
//  bandwidth, no room, no speaker, and it analyses faster than real time. A
//  mic in a sanctuary is a compromise; a purchased file is not.
//
//  Streaming subscriptions do not help: a Melon or Apple Music stream is as
//  locked as a YouTube one. The useful links here are the ones that sell a
//  file, and the worship teams' own shops, which sell MR and stems directly.
//

import Foundation

enum AudioSources {

    struct Source: Identifiable, Hashable {
        static func == (l: Source, r: Source) -> Bool { l.id == r.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        let name: String
        let detail: String
        let domain: String?
        /// True when it sells a file you keep, rather than streaming it.
        let sellsFiles: Bool
        var id: String { name }

        /// A search page of the site's own, when it has one that takes a
        /// query in the URL. Otherwise a site-restricted web search.
        var searchURL: ((String) -> URL?)? = nil

        func url(for title: String) -> URL? {
            let cleaned = SheetMusicSources.clean(title)
            if let searchURL { return searchURL(cleaned) }
            let query = domain.map { "\(cleaned) site:\($0)" } ?? "\(cleaned) 음원 MR 다운로드"
            guard let encoded = query.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) else { return nil }
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        }
    }

    /// Teams that sell their own recordings first — they are the rights
    /// holders, the quality is the master, and the money reaches the people
    /// who wrote the song.
    static let all: [Source] = [
        Source(name: "어노인팅 온라인샵", detail: "MR·음원 직접 판매",
               domain: "anointingmusic.com", sellsFiles: true),
        Source(name: "마커스 스토어", detail: "MR·음원 직접 판매",
               domain: "markersworship.com", sellsFiles: true),
        Source(name: "벅스", detail: "곡 구매 (다운로드)", domain: "bugs.co.kr", sellsFiles: true),
        Source(name: "지니", detail: "곡 구매 (다운로드)", domain: "genie.co.kr", sellsFiles: true),
        Source(name: "멜론", detail: "곡 구매 (다운로드)", domain: "melon.com", sellsFiles: true),
        Source(name: "iTunes Store", detail: "곡 구매 (다운로드)",
               domain: "music.apple.com", sellsFiles: true),
        Source(name: "MR 전체 검색", detail: "반주 음원 찾기", domain: nil, sellsFiles: true)
    ]

    /// Recordings that may be downloaded for nothing, legally.
    ///
    /// For 찬송가 and public-domain hymns only. Modern Korean CCM is almost
    /// all KOMCA-administered, and there is no free source for it that is
    /// not piracy, so none is pretended here.
    ///
    /// "The hymn is public domain" is not the same as "this file is free":
    /// the tune and original text may be, while a recording, an arrangement
    /// or a Korean translation is somebody's. Every one of these sites
    /// states a licence per file, and the sheet says to read it.
    static let free: [Source] = [
        Source(name: "공유마당", detail: "한국저작권위원회 · 만료·공개 저작물",
               domain: "gongu.copyright.or.kr", sellsFiles: false),
        Source(name: "Internet Archive", detail: "공개 음원 · 오래된 찬송 녹음",
               domain: "archive.org", sellsFiles: false,
               searchURL: { query in
                   var parts = URLComponents(string: "https://archive.org/search")
                   parts?.queryItems = [URLQueryItem(name: "query", value: query),
                                        URLQueryItem(name: "mediatype", value: "audio")]
                   return parts?.url
               }),
        Source(name: "Musopen", detail: "퍼블릭 도메인 녹음 · 클래식·찬송 선율",
               domain: "musopen.org", sellsFiles: false),
        Source(name: "hymnal.net", detail: "영어 찬송가 원곡 · 무료 MP3",
               domain: "hymnal.net", sellsFiles: false)
    ]
}
