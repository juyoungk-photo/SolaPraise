//
//  SongCompletion.swift
//  SolaPraise
//
//  찬양 검색's completions: as a title is typed, the songs it can be —
//  from what this app already knows, on the device, free and instant.
//
//  WHY NOT YOUTUBE'S OWN: the box YouTube and Google complete from is not
//  part of the YouTube API. It is an undocumented endpoint, outside the
//  terms the app's key is held under; it can change or stop without
//  notice; and every keystroke would go to Google. What a worship team
//  searches for is mostly songs it has sung, songs it has chosen a title
//  for, and songs in the channels it follows — all of which are here.
//
//  WHY JAMO: Korean is typed a letter at a time inside a syllable. 「주 경외하」
//  is on its way to 「주 경외함으로」, and 「갈」 to 「가라」; a match on whole
//  syllables misses both until the word is finished. Matching on the
//  letters (ㅈㅜㄱㅕㅇ…) — compound vowels and finals split, so 「고」
//  is on its way to 「과」 and 「달」 to 「닭」 — completes as it is typed.
//  Spaces and punctuation are ignored: 「주경외함」 is 「주 경외함으로」.
//  Initials alone, 「ㅈㄱㅇㅎ」, find it too, as Korean search boxes do.
//
//  Pure, so it is checked without a device (Tools/check-song-completion.swift).
//

import Foundation

enum SongCompletion {

    /// Where a song came from — the order is the order of trust.
    enum Source: Int, Comparable {
        /// On the team sheet's Songs tab: the team has sung it.
        case team = 0
        /// A title someone here chose for a video.
        case chosen
        /// Searched for before.
        case history
        /// In a video's title in the feed.
        case video

        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    struct Candidate {
        let text: String
        let source: Source
        /// Shown beside it: when the team last sang it, in what key.
        let detail: String?
        /// More is stronger: times sung, how recent a search was.
        let weight: Int
        fileprivate let letters: [Unicode.Scalar]
        fileprivate let initials: [Unicode.Scalar]
        /// Where each word starts in `letters`.
        fileprivate let wordStarts: [Int]

        init(text: String, source: Source, detail: String? = nil, weight: Int = 0) {
            self.text = text
            self.source = source
            self.detail = detail
            self.weight = weight
            var letters: [Unicode.Scalar] = []
            var starts: [Int] = []
            var inWord = false
            for scalar in text.unicodeScalars {
                let parts = SongCompletion.letters(of: scalar)
                if parts.isEmpty {
                    inWord = false
                    continue
                }
                if !inWord { starts.append(letters.count) }
                inWord = true
                letters += parts
            }
            self.letters = letters
            self.initials = SongCompletion.initials(text)
            self.wordStarts = starts
        }
    }

    struct Suggestion: Equatable {
        let text: String
        let source: Source
        let detail: String?
    }

    /// The songs a query can be, strongest first.
    static func suggest(_ query: String, from candidates: [Candidate], limit: Int = 8) -> [Suggestion] {
        let typed = letters(query)
        guard !typed.isEmpty else { return [] }
        var best: [String: (score: Int, candidate: Candidate)] = [:]
        for candidate in candidates {
            guard let match = score(typed: typed, query: query, candidate),
                  candidate.letters != typed else { continue }
            let score = match + (3 - candidate.source.rawValue) * 60 + min(candidate.weight, 50)
            let key = String(String.UnicodeScalarView(candidate.letters))
            if let kept = best[key], kept.score >= score { continue }
            best[key] = (score, candidate)
        }
        return best.values
            .sorted { ($0.score, -$0.candidate.text.count) > ($1.score, -$1.candidate.text.count) }
            .prefix(limit)
            .map { Suggestion(text: $0.candidate.text, source: $0.candidate.source, detail: $0.candidate.detail) }
    }

    /// Whether a title answers what is typed — the feed's own search, so it
    /// finds 「주 경외함으로」 for 「주경외함」 the way completion does.
    static func matches(_ query: String, title: String) -> Bool {
        let typed = letters(query)
        guard !typed.isEmpty else { return false }
        return score(typed: typed, query: query, Candidate(text: title, source: .video)) != nil
    }

    private static func score(typed: [Unicode.Scalar], query: String, _ candidate: Candidate) -> Int? {
        if isInitials(query) {
            let wanted = initials(query)
            guard wanted.count >= 2 else { return nil }
            if candidate.initials.starts(with: wanted) { return 300 }
            return candidate.initials.contains(wanted) ? 150 : nil
        }
        if candidate.letters.starts(with: typed) { return 400 }
        if candidate.wordStarts.contains(where: { candidate.letters[$0...].starts(with: typed) }) { return 250 }
        // Inside a word only once a syllable's worth is typed: two letters
        // match half the titles there are.
        return typed.count >= 3 && candidate.letters.contains(typed) ? 100 : nil
    }

    // MARK: - Letters

    private static let leads = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ".unicodeScalars)
    private static let vowels = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅗㅏ", "ㅗㅐ", "ㅗㅣ", "ㅛ",
                                 "ㅜ", "ㅜㅓ", "ㅜㅔ", "ㅜㅣ", "ㅠ", "ㅡ", "ㅡㅣ", "ㅣ"].map { Array($0.unicodeScalars) }
    private static let tails = ["", "ㄱ", "ㄲ", "ㄱㅅ", "ㄴ", "ㄴㅈ", "ㄴㅎ", "ㄷ", "ㄹ", "ㄹㄱ", "ㄹㅁ", "ㄹㅂ", "ㄹㅅ",
                                "ㄹㅌ", "ㄹㅍ", "ㄹㅎ", "ㅁ", "ㅂ", "ㅂㅅ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ",
                                "ㅍ", "ㅎ"].map { Array($0.unicodeScalars) }
    /// A compound letter typed on its own, as its parts.
    private static let compounds: [Unicode.Scalar: String] = [
        "ㄳ": "ㄱㅅ", "ㄵ": "ㄴㅈ", "ㄶ": "ㄴㅎ", "ㄺ": "ㄹㄱ", "ㄻ": "ㄹㅁ", "ㄼ": "ㄹㅂ", "ㄽ": "ㄹㅅ",
        "ㄾ": "ㄹㅌ", "ㄿ": "ㄹㅍ", "ㅀ": "ㄹㅎ", "ㅄ": "ㅂㅅ", "ㅘ": "ㅗㅏ", "ㅙ": "ㅗㅐ", "ㅚ": "ㅗㅣ",
        "ㅝ": "ㅜㅓ", "ㅞ": "ㅜㅔ", "ㅟ": "ㅜㅣ", "ㅢ": "ㅡㅣ",
    ]

    /// One character as the letters it is typed with; nothing for spaces
    /// and punctuation, lower case for Latin.
    fileprivate static func letters(of scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        let value = scalar.value
        if (0xAC00...0xD7A3).contains(value) {
            let index = Int(value - 0xAC00)
            return [leads[index / 588]] + vowels[(index % 588) / 28] + tails[index % 28]
        }
        if (0x3131...0x3163).contains(value) {
            return compounds[scalar].map { Array($0.unicodeScalars) } ?? [scalar]
        }
        if CharacterSet.alphanumerics.contains(scalar) {
            return Array(String(scalar).lowercased().unicodeScalars)
        }
        return []
    }

    static func letters(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.flatMap(letters(of:))
    }

    /// Each syllable's first letter; Latin and digits as themselves.
    static func initials(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.compactMap { scalar in
            let value = scalar.value
            if (0xAC00...0xD7A3).contains(value) { return leads[Int(value - 0xAC00) / 588] }
            if (0x3131...0x314E).contains(value) { return scalar }
            if CharacterSet.alphanumerics.contains(scalar) { return String(scalar).lowercased().unicodeScalars.first }
            return nil
        }
    }

    /// 「ㅈㄱㅇㅎ」: consonants alone, as typed to search by initials.
    static func isInitials(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        return !scalars.isEmpty && scalars.allSatisfy { (0x3131...0x314E).contains($0.value) }
    }
}

private extension Array where Element == Unicode.Scalar {
    func contains(_ other: [Unicode.Scalar]) -> Bool {
        guard !other.isEmpty, other.count <= count else { return other.isEmpty }
        for start in 0...(count - other.count) where self[start..<(start + other.count)].elementsEqual(other) {
            return true
        }
        return false
    }
}
