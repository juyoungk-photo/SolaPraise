//
//  VersionChips.swift
//  SolaPraise
//
//  Short names for a song's chart versions, for the stand's chips: 「콘티
//  v2」, 「악보 10/12」.
//
//  WHY: the versions were behind a menu whose entries read 「콘티 20261018
//  주일 2부예배 찬양 v2 · 3쪽」 — right, and too long to sit side by side.
//  A chip names only what tells versions apart: which 콘티, or the day a
//  chart went up. Two that would read the same are numbered, so no two
//  chips look alike (Tools/check-version-chips.swift).
//

import Foundation

enum VersionChips {

    /// One short name per version label, in the same order. `songs`: the
    /// song's title as written, so a chart named after its song is not
    /// named by it again.
    static func names(_ labels: [String], songs: [String] = []) -> [String] {
        let short = labels.map { shortName($0, songs: songs) }
        var seen: [String: Int] = [:]
        return short.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name) (\(count))"
        }
    }

    static func shortName(_ label: String, songs: [String] = []) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let head = trimmed.components(separatedBy: " · ").first ?? trimmed
        if trimmed.hasPrefix("콘티") {
            let stem = String(head.dropFirst("콘티".count)).trimmingCharacters(in: .whitespaces)
            return version(in: stem).map { "콘티 v\($0)" } ?? "콘티"
        }
        let isChart = trimmed.hasPrefix("악보")
        let file = isChart ? String(head.dropFirst("악보".count)).trimmingCharacters(in: .whitespaces) : head
        let stem = (file as NSString).deletingPathExtension
        // The key a chart is named in — 「… (A)」 — tells versions apart best.
        let key = keyInName(stem).map { " (\($0))" } ?? ""
        // 「악보 name · 10/12 올림」: the day it went up.
        if isChart, let range = trimmed.range(of: #"(\d{1,2}/\d{1,2}) 올림"#, options: .regularExpression) {
            return "악보 " + trimmed[range].replacingOccurrences(of: " 올림", with: "") + key
        }
        // Named after the song: what is left once the title is taken off.
        var rest = stem
        for song in songs.sorted(by: { $0.count > $1.count }) where !song.isEmpty && rest.hasPrefix(song) {
            rest = String(rest.dropFirst(song.count))
            break
        }
        guard rest != stem else { return (isChart ? "악보 " : "") + clipped(stem) }
        // What else the name says, less the key, which is shown on its own.
        if let named = keyInName(rest) { rest = rest.replacingOccurrences(of: "(\(named))", with: "") }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -_·"))
        return (isChart ? "악보" : "파일") + (rest.isEmpty ? "" : " " + clipped(rest)) + key
    }

    /// 「(A)」, 「(F#m)」, 「(B♭)」 in a file's name.
    private static func keyInName(_ stem: String) -> String? {
        guard let range = stem.range(of: #"\(([A-G](?:#|b|♯|♭)?m?)\)"#, options: .regularExpression) else { return nil }
        return String(stem[range].dropFirst().dropLast())
    }

    /// 「… v2」, 「… ver.3」, 「…(v4)」 at the end of a 콘티's name.
    private static func version(in stem: String) -> Int? {
        guard let range = stem.range(of: #"(?i)v(?:er)?\.?\s*(\d{1,2})\)?\s*$"#, options: .regularExpression) else {
            return nil
        }
        let digits = stem[range].filter(\.isNumber)
        return Int(digits)
    }

    private static func clipped(_ text: String, to length: Int = 10) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}
