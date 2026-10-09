//
//  SongSearchSuggestions.swift
//  SolaPraise
//
//  What to search next, from the song that is playing.
//
//  Not a general search box. Every suggestion here leads back to the same
//  four things — a 찬양, a passage of 성경, a 말씀 or 설교, a 기도 — because
//  the question being answered is "where does this song lead", not "what
//  else is on YouTube".
//
//    제목       other versions of this song
//    찬송가 N장  every recording of a hymn, which the title alone misses
//    중심 가사   the line the song keeps returning to, which finds both this
//              song and others that make the same confession
//    첫소절      how most people remember a song they cannot name
//    말씀       the passage the song is built on, which leads to readings
//              and sermons on it
//
//  WHERE THE LYRICS COME FROM: the video's own description. Worship teams
//  very often paste the lyrics there, and that is the only source the app
//  uses — nothing is scraped, nothing is fetched from a lyrics site. When a
//  description has no lyrics, 중심 가사 and 첫소절 simply do not appear.
//
//  Pure string handling, so it can be checked without a device. See
//  Tools/check-song-suggestions.swift.
//

import Foundation

struct SongSearchSuggestion: Identifiable, Equatable {
    enum Kind: String { case title, hymn, hook, firstLine, scripture }

    let kind: Kind
    /// What the chip says.
    let label: String
    /// What is searched.
    let query: String

    var id: String { kind.rawValue + query }

    var caption: String {
        switch kind {
        case .title:     return "다른 버전"
        case .hymn:      return "찬송가"
        case .hook:      return "중심 가사"
        case .firstLine: return "첫소절"
        case .scripture: return "말씀"
        }
    }
}

enum SongSearchSuggestions {

    static func make(title: String, description: String?) -> [SongSearchSuggestion] {
        var out: [SongSearchSuggestion] = []
        var seen = Set<String>()

        func add(_ kind: SongSearchSuggestion.Kind, _ text: String) {
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2 else { return }
            // Two suggestions that search the same thing are one suggestion.
            // 첫소절 is very often the title — 「어려운 일 당할 때」 starts
            // with 어려운 일 당할 때 — and offering both is offering one twice.
            let key = normalised(query)
            guard !seen.contains(where: { $0 == key || $0.contains(key) || key.contains($0) })
            else { return }
            seen.insert(key)
            out.append(SongSearchSuggestion(kind: kind, label: query, query: query))
        }

        let cleanTitle = clean(title)
        add(.title, cleanTitle)

        let corpus = title + "\n" + (description ?? "")
        if let hymn = hymnNumber(in: corpus) { add(.hymn, "찬송가 \(hymn)장") }

        let lyrics = lyricLines(in: description ?? "")
        if let hook = mostRepeated(lyrics) { add(.hook, hook) }
        if let first = lyricBlock(in: description ?? "").first { add(.firstLine, first) }

        if let passage = ScriptureReferenceText.passage(in: corpus) {
            add(.scripture, passage)
        }
        return out
    }

    // MARK: - Title

    /// The song's name without the packaging around it.
    ///
    /// Uploads wrap the title in everything else: 「주님 뜻대로 살기로 했네
    /// No Turning Back | 더라이트 워십 Live」. Searching all of that finds this
    /// one upload; searching the name finds every version, which is the
    /// point.
    static func clean(_ title: String) -> String {
        var text = title

        // Everything after a separator is the channel, the event or the
        // English title — keep the part before it.
        for separator in [" | ", "|", " / ", " - ", " — ", "｜"] {
            if let range = text.range(of: separator) {
                let head = String(text[..<range.lowerBound])
                if head.trimmingCharacters(in: .whitespaces).count >= 2 { text = head }
            }
        }
        // Bracketed asides: [4k], (Live), 【MV】, (Official).
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"【[^】]*】"#, #"「|」"#] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }
        // An English translation trailing a Korean title.
        if let range = text.range(of: #"\s[A-Z][A-Za-z' ]{3,}$"#,
                                  options: .regularExpression),
           text[..<range.lowerBound].range(of: #"\p{Hangul}"#,
                                           options: .regularExpression) != nil {
            text = String(text[..<range.lowerBound])
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Hymns

    /// 「찬송가 543장」, 「새찬송가 543장」, 「통일찬송가 342장」, 「543장」.
    static func hymnNumber(in text: String) -> Int? {
        let patterns = [#"(?:새|통일)?찬송가\s*(\d{1,3})\s*장"#, #"(?<!\d)(\d{1,3})\s*장(?!\s*\d)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let number = Int(text[range]),
                  (1...645).contains(number) else { continue }
            // A bare "N장" is only trusted when the text is plainly about a
            // hymn; elsewhere it is a chapter, as in 「시편 23장」.
            if pattern.hasPrefix("(?<!") {
                guard text.contains("찬송") else { continue }
            }
            return number
        }
        return nil
    }

    // MARK: - Lyrics

    /// Lines of a description that read as lyrics rather than credits.
    ///
    /// A description is credits, links, set lists and lyrics in one block,
    /// and the lyrics are the only part worth searching. They are the short
    /// Korean lines with no link, no handle, no timestamp and no "role:"
    /// label.
    /// The first word of a credit line, as teams write them.
    private static let roleWords: Set<String> = [
        "lyrics", "lyric", "words", "music", "composed", "composer", "arrangement",
        "arranged", "arranger", "translation", "translated",
        "vocal", "vocals", "voice", "choir", "leader", "worship",
        "piano", "keys", "keyboard", "synth", "organ", "drums", "drum", "percussion",
        "guitar", "b.guitar", "e.guitar", "a.guitar", "bass", "strings", "violin",
        "cello", "sax", "trumpet",
        "producer", "produced", "director", "directed", "videographer", "camera",
        "photographer", "photo", "editor", "edited", "video", "color", "colour",
        "subtitles", "subtitle", "foh", "engineer", "assistant", "recorded",
        "recording", "mixed", "mixing", "mastered", "mastering", "sound", "audio",
        "lighting", "light", "stage", "location", "venue", "special", "thanks",
        "sponsor", "sponsored", "design", "designer", "manager", "management"
    ]

    static func lyricLines(in description: String) -> [String] {
        let creditWords = ["작사", "작곡", "편곡", "vocal", "piano", "drum", "bass",
                           "guitar", "keys", "engineer", "믹싱", "마스터링", "촬영",
                           "영상", "제작", "후원", "문의", "copyright", "ccli",
                           "all rights", "instagram", "facebook", "구독", "좋아요",
                           "알림", "인도", "찬양팀", "worship leader", "director"]
        return description
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard (4...40).contains(line.count),
                      line.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil
                else { return false }
                let lower = line.lowercased()
                if lower.contains("http") || line.contains("@") || line.contains("#") { return false }
                if line.contains(":") || line.contains("：") { return false }
                if line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return false }
                if creditWords.contains(where: { lower.contains($0) }) { return false }
                // MUST LOOK LIKE A LYRIC, not merely fail to look like a
                // credit. A blocklist of non-lyrics kept leaking: after the
                // credits were caught, 「☎️032-551-0210 (오전 9시 - 오후 6시)」
                // became the 첫소절, because it has Hangul in it and is not a
                // credit. A sung line has no digits, and is nearly all
                // Hangul — 「예수 의지합니다」 is entirely Hangul, a phone line
                // or 「Lyrics 이동선」 is mostly not.
                if line.rangeOfCharacter(from: .decimalDigits) != nil { return false }
                guard hangulShare(of: line) >= 0.7 else { return false }
                // A note, not a lyric: 「*피아 목요 예배 녹화영상은…」.
                if line.hasPrefix("*") || line.hasPrefix("※") || line.hasPrefix("-") { return false }
                // "Mixed by 이호", "Arrangement by F.I.A".
                if lower.contains(" by ") || lower.hasSuffix(" by") { return false }
                // AN ENGLISH ROLE, THEN A KOREAN NAME.
                //
                // The format most teams use for credits — 「Lyrics 이동선」,
                // 「Vocals 김경동, 김기리」, 「Location 성락성결교회」 — and each
                // one contains Hangul, so it passed every other test and
                // 「Lyrics 이동선」 was offered as the song's 첫소절. A Korean
                // lyric line opens with Hangul; one that opens with a role
                // word is a credit.
                if let first = line.split(separator: " ").first?.lowercased(),
                   roleWords.contains(first.trimmingCharacters(in: .punctuationCharacters)) {
                    return false
                }
                return true
            }
    }

    /// Share of non-space characters that are Hangul syllables.
    static func hangulShare(of line: String) -> Double {
        let letters = line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let hangul = letters.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        return Double(hangul) / Double(letters.count)
    }

    /// The first run of three or more consecutive lyric lines.
    ///
    /// 첫소절 is taken from here rather than from the first lyric-like line
    /// anywhere, because a single stray line that happens to pass every
    /// test is still not a song's opening — a block of them is. A
    /// description with no lyric block offers no 첫소절, which is the honest
    /// answer for an upload whose description is credits and contact
    /// details.
    static func lyricBlock(in description: String) -> [String] {
        let accepted = Set(lyricLines(in: description))
        var run: [String] = []
        for raw in description.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if accepted.contains(line) {
                run.append(line)
            } else {
                if run.count >= 3 { return run }
                run = []
            }
        }
        return run.count >= 3 ? run : []
    }

    /// The line sung most often — the hook — when one is sung more than once.
    ///
    /// A chorus repeats and a verse does not, so the most frequent line of
    /// the lyrics is the one the song is built around: 「예수 의지합니다」 in
    /// 「어려운 일 당할 때」. A song printed with no repeats has no hook to
    /// offer, and inventing one from a verse line would be wrong.
    static func mostRepeated(_ lines: [String]) -> String? {
        var counts: [String: (count: Int, first: Int, text: String)] = [:]
        for (index, line) in lines.enumerated() {
            let key = normalised(line)
            if let existing = counts[key] {
                counts[key] = (existing.count + 1, existing.first, existing.text)
            } else {
                counts[key] = (1, index, line)
            }
        }
        return counts.values
            .filter { $0.count >= 2 }
            .max { a, b in a.count != b.count ? a.count < b.count : a.first > b.first }?
            .text
    }

    // MARK: - Helpers

    /// For comparison only: no spaces, no punctuation, lowercased.
    static func normalised(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[\s\p{P}]"#, with: "", options: .regularExpression)
    }
}

/// The scripture half, as plain text, so this file stays free of the
/// player's types and can be compiled on its own.
enum ScriptureReferenceText {
    /// "시편 23편", "요한복음 3:16" — the first reference in the text.
    static func passage(in text: String) -> String? {
        let books = ["창세기","출애굽기","레위기","민수기","신명기","여호수아","사사기","룻기",
                     "사무엘상","사무엘하","열왕기상","열왕기하","역대상","역대하","에스라",
                     "느헤미야","에스더","욥기","시편","잠언","전도서","아가","이사야",
                     "예레미야애가","예레미야","에스겔","다니엘","호세아","요엘","아모스",
                     "오바댜","요나","미가","나훔","하박국","스바냐","학개","스가랴","말라기",
                     "마태복음","마가복음","누가복음","요한복음","사도행전","로마서",
                     "고린도전서","고린도후서","갈라디아서","에베소서","빌립보서","골로새서",
                     "데살로니가전서","데살로니가후서","디모데전서","디모데후서","디도서",
                     "빌레몬서","히브리서","야고보서","베드로전서","베드로후서","요한일서",
                     "요한이서","요한삼서","유다서","요한계시록"]
        // Longest first, so 요한복음 is not read as 요한 and 예레미야애가 is
        // not read as 예레미야.
        for book in books.sorted(by: { $0.count > $1.count }) {
            let pattern = book + #"\s*(\d{1,3})\s*(?:[편장]|:\s*(\d{1,3})(?:\s*-\s*(\d{1,3}))?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text) else { continue }
            return String(text[whole]).replacingOccurrences(of: #"\s+"#, with: " ",
                                                             options: .regularExpression)
        }
        return nil
    }
}
