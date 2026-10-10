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

    static func make(title: String, description: String?,
                     channel: String? = nil) -> [SongSearchSuggestion] {
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

        // A medley names two songs; both are worth searching.
        for song in songTitles(title: title, description: description ?? "", channel: channel) {
            add(.title, song)
        }

        let corpus = title + "\n" + (description ?? "")
        // The title's number first: a description can mention others —
        // 「찬송가 1장부터 645장까지」 is a channel's blurb, not this song.
        if let hymn = hymnNumber(in: title) ?? hymnNumber(in: description ?? "") {
            add(.hymn, "찬송가 \(hymn)장")
        }

        // Lines that name the team or the channel are not lyrics, however
        // much they read like one — 「어노인팅 채널」, 「마커스 목요예배」.
        let team = teamWords(channel: channel)
        let notTeam: (String) -> Bool = { line in !mentionsTeam(line, team) }
        let lyrics = lyricLines(in: description ?? "").filter(notTeam)
        if let hook = mostRepeated(lyrics) { add(.hook, hook) }
        if let first = lyricBlock(in: description ?? "").first(where: notTeam) {
            add(.firstLine, first)
        }

        if let passage = ScriptureReferenceText.passage(in: corpus) {
            add(.scripture, passage)
        }
        return out
    }

    // MARK: - Title

    /// The song (or songs, for a medley) a video is of, best first. Empty
    /// when the title names no song at all — a service stream, a teaser.
    ///
    /// The title is cut at every separator teams use, and each part is
    /// judged on its own. Keeping simply the part before the first
    /// separator — the old rule — was right for 「은혜 | 손경민」 and wrong
    /// for most of a real feed, measured on 96 recent uploads:
    ///
    ///   간미연 - 너 근심 걱정 말아라 | Delivery Project   → the singer
    ///   출근길에 딱 - 선하신 목자                          → the headline
    ///   은밀한 곳 조용한 곳에ㅣANOINTING CLIP             → kept 「ㅣANOINTING CLIP」
    ///   2026_1001ㅣ어노인팅목요예배ㅣ인도_ 소병찬          → a service, not a song
    ///   01. 은혜                                           → the track number
    ///
    /// The description settles the hard ones. Teams tag the song itself
    /// (#선하신목자), open with its title, and list singers in credits —
    /// so a part that matches a hashtag or the first line wins, and one
    /// that appears in a credit line is a person.
    static func songTitles(title: String, description: String, channel: String?) -> [String] {
        // Split BEFORE the compatibility mapping that turns 𝑳𝒊𝒗𝒆 into
        // Live: it also turns the 「ㅣ」 teams use as a bar into a different
        // character, and 「은밀한 곳 조용한 곳에ㅣANOINTING CLIP」 stopped
        // splitting at all.
        let text = title
        let team = teamWords(channel: channel)
        let tags = hashtags(in: text + "\n" + description)
        let firstLine = description.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.lowercased().contains("http") }
            .map(normalised) ?? ""
        let credits = creditLines(in: description).map(normalised)

        // Hashtag-only titles: 「#깨끗한손주옵소서 #giveuscleanhands」.
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let words = text.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            if let korean = words.first(where: { hangulShare(of: $0) > 0.5 }) { return [korean] }
            return words.first.map { [$0] } ?? []
        }

        struct Candidate { let text: String; let score: Int; let position: Int; let medley: Int }
        var candidates: [Candidate] = []
        for (position, rawPart) in parts(of: text).enumerated() {
            let part = rawPart.precomposedStringWithCompatibilityMapping
            for (medleyIndex, piece) in part.components(separatedBy: " + ").enumerated() {
                guard !isPackaging(piece, team: team) else { continue }
                var hymn = false
                let song = cleanPart(piece, hymn: &hymn)
                // A song title has no digits once its hymn and track
                // numbers are gone; 「27년 1/28」 is a date.
                guard song.count >= 2, hangulShare(of: song) >= 0.5 || song.count >= 4,
                      song.rangeOfCharacter(from: .decimalDigits) == nil,
                      !isPackaging(song, team: team) else { continue }
                let key = normalised(song)
                guard !key.isEmpty else { continue }
                var score = 0
                if tags.contains(key) { score += 6 }
                if !firstLine.isEmpty, firstLine.hasPrefix(key) || key.hasPrefix(firstLine) { score += 3 }
                if hymn { score += 3 }
                if hangulShare(of: song) >= 0.7 { score += 1 }
                // A name in the credits is a person, not a song: 「범키」,
                // 「간미연」. Only short, single-word parts — a real title
                // can appear in a credit line as 「곡: 은혜」.
                if !song.contains(" "), song.count <= 4,
                   credits.contains(where: { $0.contains(key) }) { score -= 6 }
                candidates.append(Candidate(text: song, score: score,
                                            position: position, medley: medleyIndex))
            }
        }
        guard let best = candidates.max(by: { a, b in
            a.score != b.score ? a.score < b.score
                : (a.position != b.position ? a.position > b.position : a.medley > b.medley)
        }) else { return [] }

        // The other song of a medley rides along: 「A + B」 is two songs.
        let partners = candidates.filter {
            $0.position == best.position && $0.medley != best.medley && $0.score >= best.score - 1
        }
        return [best.text] + partners.prefix(1).map(\.text)
    }

    /// Cut at every separator teams put between the song and its packaging.
    static func parts(of title: String) -> [String] {
        var pieces = [title]
        // 「ㅣ」 (the Hangul vowel) and a spaced 「l」/「I」 are used as bars;
        // " I " only counts in a Korean title, where it cannot be the word.
        var separators = [" | ", "|", "｜", "ㅣ", " / ", " - ", " — ", " – ", " l "]
        if title.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil { separators.append(" I ") }
        for separator in separators {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// One part with its asides removed: brackets, track numbers, hymn
    /// numbers, keys, an English translation trailing the Korean.
    static func cleanPart(_ raw: String, hymn: inout Bool) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"【[^】]*】"#, #"「|」|"|“|”"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 「찬송가 543장」, a trailing 「543장」 — the song is what is left.
        if text.range(of: #"(?:새|통일)?찬송가\s*\d{1,3}\s*장|\d{1,3}\s*장"#, options: .regularExpression) != nil {
            hymn = true
            text = text.replacingOccurrences(of: #"(?:새|통일)?찬송가\s*\d{1,3}\s*장|\d{1,3}\s*장"#,
                                             with: " ", options: .regularExpression)
        }
        // A leading track number: 「01. 은혜」, 「3) 주님」, 「#2 임재」,
        // 「Track 5 은혜」 — never a year or a hymn, both handled above.
        text = text.replacingOccurrences(of: #"^\s*(?:track\s*)?#?\d{1,3}\s*[.)_:\-]?\s+"#,
                                         with: "", options: [.regularExpression, .caseInsensitive])
        // Packaging words inside the part.
        text = text.replacingOccurrences(
            of: #"(?i)\b(?:mr|inst|kor\s*sub|eng\s*sub|official|mv|m/v|lyrics?|live|ver\.?|version|acoustic|cover)\b|가사\s*포함|가사|반주"#,
            with: " ", options: .regularExpression)
        // Emoji and symbols.
        text = String(text.unicodeScalars.filter {
            !($0.properties.isEmojiPresentation || $0.properties.generalCategory == .otherSymbol)
        }.map(Character.init))
        // An English translation trailing a Korean title.
        if let range = text.range(of: #"(?<=\p{Hangul})\s+[A-Za-z][A-Za-z0-9 ,'’!?.&]*$"#,
                                  options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Words that mark a part as the team, the event, or the format rather
    /// than the song.
    private static let packaging = [
        "워십", "worship", "project", "프로젝트", "clip", "클립", "streaming", "스트리밍",
        "목요예배", "주일예배", "수요예배", "금요예배", "새벽예배", "화요모임", "예배실황", "실황",
        "찬양팀", "컨퍼런스", "conference", "teaser", "티저", "camp", "캠프", "소식",
        "플레이리스트", "playlist", "연속 듣기", "연속듣기", "모음", "보컬 클래스",
        "인도_", "인도:", "설교", "sermon"
    ]

    static func isPackaging(_ part: String, team: [String]) -> Bool {
        let lower = part.lowercased()
        if packaging.contains(where: { lower.contains($0) }) { return true }
        if mentionsTeam(part, team) { return true }
        // An episode, a date, a key, a run time.
        if lower.range(of: #"^ep\.?\s*\d|^\d{4}[-_.]|^20\d\d\b|^\d{1,2}\.\d{1,2}\.\d{2,4}|^[a-g][#b♭]?(?:-[a-g][#b♭]?)?\s*key$|^\d+\s*(시간|분)"#,
                       options: .regularExpression) != nil { return true }
        return false
    }

    /// The channel's own name, word by word, for spotting it in titles and
    /// descriptions: 「MARKERS WORSHIP」 → markers, worship.
    static func teamWords(channel: String?) -> [String] {
        guard let channel else { return [] }
        // Latin words need four letters and must not be common words:
        // 「더라이트 The Light」 made 「the」 a team word, and every hymn
        // with an English title — 「All the Way My Savior Leads Me」 —
        // was thrown out as the team's name.
        let common: Set<String> = ["the", "and", "for", "with", "you", "our", "of", "official", "music", "church"]
        return channel.precomposedStringWithCompatibilityMapping
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                guard !common.contains(word) else { return false }
                return word.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil
                    ? word.count >= 2 : word.count >= 4
            }
    }

    static func mentionsTeam(_ text: String, _ team: [String]) -> Bool {
        guard !team.isEmpty else { return false }
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        let joined = normalised(text)
        return team.contains { words.contains($0) || ($0.count >= 4 && joined.contains($0)) }
    }

    /// #선하신목자 → 선하신목자, normalised.
    static func hashtags(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"#([\p{L}\p{N}_]+)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { normalised(String(text[$0])) }
        })
    }

    /// Lines that credit people: 「Voc | 권기범(범키)」, 「• Piano 권예은」.
    static func creditLines(in description: String) -> [String] {
        description.components(separatedBy: .newlines).filter { line in
            let lower = line.lowercased()
            let words = lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            return words.contains { roleWords.contains($0) || ["voc", "lead", "인도", "보컬", "건반"].contains($0) }
        }
    }

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
        // Not a range: 「1장부터」, 「645장까지」, 「1~645장」.
        let patterns = [#"(?:새|통일)?찬송가\s*(\d{1,3})\s*장(?!\s*(?:부터|까지|~))"#,
                        #"(?<![\d~])(\d{1,3})\s*장(?!\s*(?:\d|부터|까지|~))"#]
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
                           "알림", "인도:", "인도_", "인도 :", "찬양팀", "worship leader", "director"]
        // Not a bare 「인도」: as a role it is written 「인도: 이름」, and as
        // a word it is all over hymns — 「예수 인도하시니」 was rejected as
        // a credit, which broke the verse and moved 첫소절 to its third line.
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
                // An event or a team, not a lyric: 「예수전도단 화요모임」.
                if isPackaging(line, team: []) { return false }
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
                // Prose, not a lyric: 「어쿠스틱 기타 한 대로 다시 불렀습니다.」
                // Sung lines are not written with a closing full stop.
                if line.hasSuffix(".") || line.hasSuffix("…") || line.hasSuffix("다!") { return false }
                // A list of names: 「윤기현 조성민」, 「곽세아, 김다솜, 김서희」.
                if isNameList(line) { return false }
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

    /// Common Korean surnames, for telling a list of people from a lyric.
    private static let surnames = Set("김이박최정강조윤장임한오서신권황안송류전홍고문양손배백허유남심노하곽성차주우구민나진지엄채원천방공현함변염여추도소석선설마길연위표명기반왕금옥육인맹제모탁국어은편용예경봉")

    /// Every word a three-syllable Hangul name with a common surname, and
    /// at least two of them. 「주님의 사랑이」 fails on 사; a lyric made only
    /// of surname-led three-syllable words is rare enough to accept.
    static func isNameList(_ line: String) -> Bool {
        let words = line.replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        guard words.count >= 2 else { return false }
        return words.allSatisfy { word in
            word.count == 3 && hangulShare(of: word) == 1
                && word.first.map { surnames.contains($0) } == true
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
        // A run of one-word lines is a list — guest teams, places — not
        // a verse: 「제이어스」 was offered as a song's first line.
        func isVerse(_ run: [String]) -> Bool {
            guard run.count >= 3 else { return false }
            let words = run.reduce(0) { $0 + $1.split(separator: " ").count }
            return Double(words) / Double(run.count) >= 2
        }
        var run: [String] = []
        for raw in description.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if accepted.contains(line) {
                run.append(line)
            } else {
                // A run that ends in a full-stop sentence was the start of
                // that sentence: 「이 시간을 통해 조용히 주님 앞에 머물며, /
                // … / 함께 기도해 주시길 바랍니다.」 is a paragraph, not a verse.
                let closesSentence = line.hasSuffix(".") && hangulShare(of: line) > 0.5
                if isVerse(run), !closesSentence { return run }
                run = []
            }
        }
        return isVerse(run) ? run : []
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
