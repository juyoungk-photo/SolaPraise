//
//  ScorePageMatcher.swift
//  SolaPraise
//
//  Which song each page of a 콘티 file is: a teammate's PDF of the whole
//  set — every song, or some of them — split back onto the 순서.
//
//  A chart names its song at the top, in its largest type. Each page's top
//  lines are compared with the 순서's titles, spaces and punctuation set
//  aside; a page whose top names no song is the next page of the one
//  before it, as the second page of a long chart is. Pure, so it is
//  checked without the app (Tools/check-page-matcher.swift).
//

import Foundation

enum ScorePageMatcher {

    /// Page index → song title, for the pages that could be placed.
    ///
    /// - pageTitles: per page, the lines at its top, largest type first.
    static func assign(pageTitles: [[String]], songs: [String]) -> [Int: String] {
        // Pass 1: a page whose title names a song is that song.
        var named: [Int: String] = [:]
        for (page, lines) in pageTitles.enumerated() {
            if let song = best(lines, songs) { named[page] = song }
        }

        // Pass 2: a page that opens a chart but whose title matched nothing
        // — a different spelling, an English title, a title set as an
        // image — takes the next song of the 순서 not yet placed, when it
        // sits between pages that keep the 순서's order. A 콘티 is made in
        // the order it is sung; one teammate's file matched only its first
        // page by title, and every other page was left for nobody.
        var result = named
        var used = Set(named.values)
        var lastSong = -1
        for page in pageTitles.indices {
            if let song = named[page], let index = songs.firstIndex(of: song) {
                lastSong = max(lastSong, index)
                continue
            }
            guard looksLikeAnotherTitle(pageTitles[page]) else { continue }
            // The next unplaced song after the last one placed, and before
            // the next page that names one.
            let nextNamed = named.filter { $0.key > page }.min { $0.key < $1.key }
                .flatMap { songs.firstIndex(of: $0.value) } ?? songs.count
            if let index = songs.indices.first(where: { $0 > lastSong && $0 < nextNamed && !used.contains(songs[$0]) }),
               plausible(pageTitles[page], songs[index]) {
                result[page] = songs[index]
                used.insert(songs[index])
                lastSong = index
            }
        }

        // Pass 3: a page with no title of its own continues the song before.
        var previous: String?
        for page in pageTitles.indices {
            if let song = result[page] {
                previous = song
            } else if let previous, !looksLikeAnotherTitle(pageTitles[page]) {
                result[page] = previous
            } else {
                previous = nil
            }
        }
        return result
    }

    /// The song a page's top lines name, if any does clearly.
    static func best(_ lines: [String], _ songs: [String]) -> String? {
        var scored: [(song: String, score: Double)] = []
        for song in songs {
            let key = normalised(song)
            guard key.count >= 2 else { continue }
            var top = 0.0
            for line in lines.prefix(4) {
                let text = normalised(line)
                guard text.count >= 2 else { continue }
                if text == key { top = max(top, 1) }
                else if text.contains(key) || (key.contains(text) && text.count >= max(3, key.count / 2)) {
                    top = max(top, 0.9)
                } else {
                    top = max(top, similarity(text, key))
                }
            }
            scored.append((song, top))
        }
        guard let winner = scored.max(by: { $0.score < $1.score }), winner.score >= 0.72 else { return nil }
        // Two songs scoring alike — 「주님」 and 「주님 뜻대로」 — the longer,
        // more specific title wins only if it is clearly ahead.
        return winner.song
    }

    /// Whether a page's title could be this song under another spelling:
    /// its Korean shares at least a third with the song's, or it has no
    /// Korean to judge by (an English title). 「은혜 아니면」 is not 「주님
    /// 뜻대로 살기로 했네」 and is left unplaced.
    private static func plausible(_ lines: [String], _ song: String) -> Bool {
        func hangul(_ text: String) -> String {
            String(text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.map(Character.init))
        }
        let title = lines.prefix(2).map(hangul).max { $0.count < $1.count } ?? ""
        guard title.count >= 2 else { return true }
        return similarity(title, hangul(song)) >= 0.35
    }

    /// A page that opens with a big title of its own — a song not in this
    /// 순서 — is not a continuation of the page before.
    private static func looksLikeAnotherTitle(_ lines: [String]) -> Bool {
        guard let first = lines.first else { return false }
        let hangul = first.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        return hangul >= 3
    }

    static func normalised(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Longest common subsequence over the longer length: OCR drops or
    /// swaps a syllable — 「거룩하신 전능의 주」 read 「거룩하신 전능의주」.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var diagonal = 0
            for j in 1...y.count {
                let above = row[j]
                row[j] = x[i - 1] == y[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return Double(row[y.count]) / Double(max(x.count, y.count))
    }
}
