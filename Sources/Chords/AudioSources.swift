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
        let name: String
        let detail: String
        let domain: String?
        /// True when it sells a file you keep, rather than streaming it.
        let sellsFiles: Bool
        var id: String { name }

        func url(for title: String) -> URL? {
            let cleaned = SheetMusicSources.clean(title)
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
}
