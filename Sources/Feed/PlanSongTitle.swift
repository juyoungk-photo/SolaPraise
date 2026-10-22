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

        // WHICH PIECES ARE THE RECORDING. The song's English title is not:
        // teams print it right after the Korean — the next part, 「곡 |
        // ENGLISH TITLE | 팀」, or in parentheses beside it — and it is the
        // same song again. Beside the title in its own part, only what says
        // something about this version is kept — 「cover by …」, a series
        // 「찬송과 묵상 #35」 — not the English 「No Turning Back」.
        let team = SongSearchSuggestions.teamWords(channel: channel)
        let parts = SongSearchSuggestions.parts(of: text)
        let songPart = parts.firstIndex { part in songs.contains { part.contains($0) } }
        for (index, part) in parts.enumerated() {
            let isSongPart = index == songPart
            var rest = part
            for (pattern, aside) in [(#"\[([^\]]*)\]"#, false), (#"【([^】]*)】"#, false), (#"\(([^)]*)\)"#, true)] {
                guard let regex = NSRegularExpression.cached(pattern) else { continue }
                let range = NSRange(rest.startIndex..., in: rest)
                for match in regex.matches(in: rest, range: range) {
                    guard let inner = Range(match.range(at: 1), in: rest) else { continue }
                    let piece = String(rest[inner])
                    // 「빚진 자 (The Debtor)」: the title again. A [tag] is not.
                    if isSongPart, aside, isEnglishTitle(piece, team: team) { continue }
                    add(piece)
                }
                rest = regex.stringByReplacingMatches(in: rest, range: range, withTemplate: " ")
            }
            if isSongPart {
                for song in songs { rest = rest.replacingOccurrences(of: song, with: " ") }
                if says(aboutVersion: rest) { add(rest) }
                continue
            }
            if let songPart, index == songPart + 1, isEnglishTitle(rest, team: team) { continue }
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

    /// Every reading of a video's title as a song, the split's own first:
    /// for when it took an album or a worship series for the song. Each
    /// part of the title between its separators and brackets, less the
    /// team, packaging and years — and the title as it came, last.
    static func candidates(_ raw: String, channel: String? = nil) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        var seen = Set<String>()
        func add(_ piece: String) {
            let text = tidy(piece)
            let key = SongSearchSuggestions.normalised(text)
            guard text.count >= 2, !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            out.append(text)
        }
        add(split(trimmed, channel: channel).title)

        let team = SongSearchSuggestions.teamWords(channel: channel)
        let yearPattern = #"(?<![0-9])(?:19|20)\d{2}(?![0-9])"#
        let text = trimmed.replacingOccurrences(of: yearPattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)찬송가\s*\d+\s*장|\d+\s*장"#, with: " ", options: .regularExpression)
        func song(_ piece: String) -> Bool {
            let text = tidy(piece)
            return text.range(of: #"[\p{Hangul}A-Za-z]"#, options: .regularExpression) != nil
                && !SongSearchSuggestions.isPackaging(text, team: team)
                && !SongSearchSuggestions.mentionsTeam(text, team)
                // Who wrote it — 「이름 사,곡」, 「작사 이름」 — is no song.
                && text.range(of: #"(작사|작곡|편곡|사\s*[,/·]\s*곡|\s(사|곡)$)"#, options: .regularExpression) == nil
        }
        for part in SongSearchSuggestions.parts(of: text) {
            var rest = part
            for pattern in [#"\[([^\]]*)\]"#, #"【([^】]*)】"#, #"\(([^)]*)\)"#] {
                guard let regex = NSRegularExpression.cached(pattern) else { continue }
                let range = NSRange(rest.startIndex..., in: rest)
                for match in regex.matches(in: rest, range: range) {
                    if let inner = Range(match.range(at: 1), in: rest), song(String(rest[inner])) { add(String(rest[inner])) }
                }
                rest = regex.stringByReplacingMatches(in: rest, range: range, withTemplate: " ")
            }
            if song(rest) { add(rest) }
        }
        add(trimmed)
        return out
    }

    /// Latin words only, naming no team and no packaging: a song's English
    /// title — 「YOU ARE HOLY」, 「Living Hope」.
    private static func isEnglishTitle(_ piece: String, team: [String]) -> Bool {
        let text = tidy(piece)
        guard !text.isEmpty, text.range(of: #"[\p{Hangul}0-9]"#, options: .regularExpression) == nil,
              text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil else { return false }
        return !SongSearchSuggestions.isPackaging(text, team: team) && !says(aboutVersion: text)
    }

    /// Words that describe a version rather than name a song.
    private static func says(aboutVersion piece: String) -> Bool {
        let text = tidy(piece)
        guard !text.isEmpty else { return false }
        if text.range(of: #"[\p{Hangul}0-9]"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"(?i)\b(cover|by|feat|ft|solo|ver|version|live|acoustic|piano|inst|remix|arr)\b|\.ver"#,
                          options: .regularExpression) != nil
    }

    // MARK: - On the sheet

    /// The Songs tab's Title and 참고버전 for a song as it arrived — a
    /// video's title, or a title typed by hand.
    ///
    /// Title is the song, with its hymn number when it has one —
    /// 「어려운 일 당할 때 (찬송가 543장)」 — since a congregation finds a
    /// hymn by its number, and 통일 and 새 number differently. 참고버전 is
    /// which recording: team, album, year. Reading the result again gives
    /// the same result, so a title already tidied is left alone.
    static func forSheet(_ raw: String, channel: String? = nil) -> (title: String, reference: String) {
        let parts = split(raw, channel: channel)
        var title = parts.title
        if let hymn = parts.hymn {
            let hymnal = raw.contains("통일") ? "통일찬송가" : "찬송가"
            title += " (\(hymnal) \(hymn)장)"
        }
        return (title, parts.meta.joined(separator: " · "))
    }

    /// Whether two titles name the same song — a video's long title and the
    /// tidied one, or the same title spelled with other packaging. What
    /// was kept against a title (a 콘티's pages, an attachment) still
    /// belongs to it after the sheet's titles are tidied.
    static func sameSong(_ a: String, _ b: String) -> Bool {
        let left = a.trimmingCharacters(in: .whitespaces), right = b.trimmingCharacters(in: .whitespaces)
        if left == right { return true }
        guard !left.isEmpty, !right.isEmpty else { return false }
        let l = identity(left), r = identity(right)
        // A number on one side only is the same hymn written two ways.
        return l.title == r.title && (l.hymn == nil || r.hymn == nil || l.hymn == r.hymn)
    }

    /// The song a title names, normalised — kept, since it is asked for
    /// every attachment and 콘티 page on every redraw.
    private static func identity(_ title: String) -> (title: String, hymn: Int?) {
        lock.lock()
        if let known = identities[title] { lock.unlock(); return known }
        lock.unlock()
        let parts = split(title)
        let found = (SongSearchSuggestions.normalised(parts.title), parts.hymn)
        lock.lock(); identities[title] = found; lock.unlock()
        return found
    }
    private static var identities: [String: (title: String, hymn: Int?)] = [:]
    private static let lock = NSLock()

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = NSRegularExpression.cached(pattern) else { return [] }
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
        // A channel's hashtag — 「#찬송가부르기」 — not a series number 「#35」.
        text = text.replacingOccurrences(of: #"#[^\s\d#][^\s#]*"#, with: " ", options: .regularExpression)
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
