//
//  PlanSongTitle.swift
//  SolaPraise
//
//  A 순서 song's line, read as the song first and the rest after it.
//
//  WHY: a song goes into the 순서 with the title of the video it was
//  taken from — 「[찬송가 288장] 예수를 나의 구주 삼고 | 팀이름 Official
//  2019」. On a 순서 the song is what a singer is looking for, and it was
//  somewhere in the middle. Now the song comes first; the hymn number
//  stays beside it, because a congregation finds a hymn by its number; and
//  what is left — the team, the year, the album — is one quieter line
//  that says which recording this is.
//
//  The title is found the way the player's suggestions find it
//  (SongSearchSuggestions.songTitles). A line the app cannot read a song
//  out of is shown as it was typed. Foundation only, so
//  Tools/check-plan-song-title.swift runs it.
//

import Foundation

enum PlanSongTitle {

    struct Parts: Equatable {
        /// The song — two, for a medley, joined with 「 + 」.
        let title: String
        let hymn: Int?
        /// Which recording: the team, the year, the album — in the order
        /// the title gives them.
        let meta: [String]
    }

    static func split(_ raw: String, channel: String? = nil) -> Parts {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hymn = SongSearchSuggestions.hymnNumber(in: trimmed)
        // A year, wherever it stands, is the recording's — and a part with
        // a number in it is never taken for a song, so 「곡 2023」 was not
        // read as a song at all. Read without it; shown after.
        let yearPattern = #"(?<![0-9])(?:19|20)\d{2}(?![0-9])"#
        let years = matches(yearPattern, in: trimmed)
        let text = trimmed.replacingOccurrences(of: yearPattern, with: " ", options: .regularExpression)
        let songs = SongSearchSuggestions.songTitles(title: text, description: "", channel: channel)
        guard !songs.isEmpty else { return Parts(title: trimmed, hymn: hymn, meta: []) }

        let songKeys = songs.map(SongSearchSuggestions.normalised)
        var meta: [String] = []
        var seen = Set<String>()
        func add(_ piece: String) {
            let text = tidy(piece)
            let key = SongSearchSuggestions.normalised(text)
            guard text.count >= 2, !key.isEmpty,
                  !songKeys.contains(where: { key == $0 || $0.contains(key) }),
                  !seen.contains(where: { $0 == key || $0.contains(key) || key.contains($0) }) else { return }
            seen.insert(key)
            meta.append(text)
        }

        for part in SongSearchSuggestions.parts(of: text) {
            // A bracketed tag is a piece of its own: 「[팀이름] 곡」.
            var rest = part
            for pattern in [#"\[([^\]]*)\]"#, #"【([^】]*)】"#, #"\(([^)]*)\)"#] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(rest.startIndex..., in: rest)
                for match in regex.matches(in: rest, range: range) {
                    if let inner = Range(match.range(at: 1), in: rest) { add(String(rest[inner])) }
                }
                rest = regex.stringByReplacingMatches(in: rest, range: range, withTemplate: " ")
            }
            // Beside the song in the same part is the song again in English,
            // or a word like 「Live」: not meta.
            if songs.contains(where: { rest.contains($0) }) { continue }
            add(rest)
        }
        years.forEach(add)
        // The team, when the title does not say it.
        if let channel, !channel.isEmpty, !meta.contains(where: {
            SongSearchSuggestions.mentionsTeam($0, SongSearchSuggestions.teamWords(channel: channel))
        }) {
            add(channel)
        }
        return Parts(title: songs.joined(separator: " + "), hymn: hymn, meta: meta)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// A meta piece without what says nothing about the recording: hymn
    /// numbers (shown beside the title), packaging words, quote marks.
    private static func tidy(_ piece: String) -> String {
        var text = piece
        text = text.replacingOccurrences(of: #"(?:새|통일)?찬송가\s*\d{1,3}\s*장|(?<![\d])\d{1,3}\s*장"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)\b(?:official|mv|m/v|lyrics?(?:\s*video)?|audio|4k|hd|kor\s*sub|eng\s*sub|full\s*ver\.?)\b|가사\s*포함|가사|\bmr\b"#,
            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"['‘’"“”「」『』]"#, with: " ", options: .regularExpression)
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
