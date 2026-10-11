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
        var result: [Int: String] = [:]
        var previous: String?
        for (page, lines) in pageTitles.enumerated() {
            if let song = best(lines, songs) {
                result[page] = song
                previous = song
            } else if let previous, !looksLikeAnotherTitle(lines) {
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
