//
//  VersionChips.swift
//  SolaPraise
//
//  Short names for a song's chart versions, for the stand's chips: 「콘티
//  v2」, 「악보 A · 주영」.
//
//  WHY: the versions were behind a menu whose entries read 「콘티 20261018
//  주일 2부예배 찬양 v2 · 3쪽」 — right, and too long to sit side by side.
//  A chip names only what tells versions apart: which 콘티; for a chart,
//  the key it is in and who put it up. The day it went up says little —
//  most of a song's charts go up the same week — so it is used only when
//  nothing else separates two chips, and then a number. No two chips look
//  alike (Tools/check-version-chips.swift).
//

import Foundation

enum VersionChips {

    struct Version {
        /// As ServicePrepView.songVersions writes it, or the file's name.
        var label: String
        /// The key the chart is in, when known: from its name, or from its
        /// chords as read on this device.
        var key: String? = nil
        /// Who put it up, as the roster names them.
        var by: String? = nil
    }

    /// One short name per version, in the same order. `songs`: the song's
    /// title as written, so a chart named after its song is not named by
    /// it again.
    static func names(_ versions: [Version], songs: [String] = []) -> [String] {
        var names = versions.map { shortName($0, songs: songs) }
        // Alike: the day it went up, where that differs.
        for name in Set(names) where names.filter({ $0 == name }).count > 1 {
            let indices = names.indices.filter { names[$0] == name }
            let days = indices.map { day(in: versions[$0].label) }
            if Set(days.compactMap { $0 }).count > 1 {
                for (k, index) in indices.enumerated() {
                    if let day = days[k] { names[index] += " · " + day }
                }
            }
        }
        // Still alike: numbered.
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name) (\(count))"
        }
    }

    static func shortName(_ version: Version, songs: [String] = []) -> String {
        let trimmed = version.label.trimmingCharacters(in: .whitespaces)
        let head = trimmed.components(separatedBy: " · ").first ?? trimmed
        if trimmed.hasPrefix("콘티") {
            let stem = String(head.dropFirst("콘티".count)).trimmingCharacters(in: .whitespaces)
            return self.version(in: stem).map { "콘티 v\($0)" } ?? "콘티"
        }
        let isChart = trimmed.hasPrefix("악보")
        let file = isChart ? String(head.dropFirst("악보".count)).trimmingCharacters(in: .whitespaces) : head
        let stem = (file as NSString).deletingPathExtension
        let key = keyInName(stem) ?? version.key

        // What else the name says, once the song's title and the key are
        // taken off — 「리드시트」 — and nothing when it is only an upload's
        // generated name.
        var rest = stem
        for song in songs.sorted(by: { $0.count > $1.count }) where !song.isEmpty && rest.hasPrefix(song) {
            rest = String(rest.dropFirst(song.count))
            break
        }
        if let named = keyInName(rest) { rest = rest.replacingOccurrences(of: "(\(named))", with: "") }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -_·"))
        if isGenerated(rest) { rest = "" }

        let parts = [key, rest.isEmpty ? nil : clipped(rest), version.by].compactMap { $0 }
        let prefix = isChart ? "악보" : "파일"
        return parts.isEmpty ? prefix : prefix + " " + parts.joined(separator: " · ")
    }

    /// 「10/12」 from 「… · 10/12 올림」.
    private static func day(in label: String) -> String? {
        guard let range = label.range(of: #"\d{1,2}/\d{1,2}(?= 올림)"#, options: .regularExpression) else { return nil }
        return String(label[range])
    }

    /// The name AttachmentMenu gives an upload — 「20261018-곡-1760000000-AB12」 —
    /// says nothing a chip needs.
    private static func isGenerated(_ text: String) -> Bool {
        text.range(of: #"(^\d{8}-)|(-\d{9,}(-[0-9A-Fa-f]{4})?$)"#, options: .regularExpression) != nil
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
