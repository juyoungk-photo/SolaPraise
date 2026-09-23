//
//  BibleModels.swift
//  SolaPraise
//
//  Value types for the daily reading.
//
//  TRANSLATION LICENSING — the constraint that shapes this whole layer:
//
//  • 개역한글 (KRV): copyright expired in 2012 (대한성서공회's own copyright FAQ),
//    so it ships bundled and fully offline. 동일성유지권 still applies, so the
//    verse text is never altered and attribution is always displayed.
//  • 개역개정: still owned by 대한성서공회 and NOT bundled. Once a licence is
//    granted it drops in as another `psalms-<code>.json` with no code change.
//  • ESV: Crossway's. Fetched live from api.esv.org under a non-commercial key.
//    Their terms cap local storage at 500 verses or half a book, whichever is
//    less — for Psalms (2,461 verses) that means 500 — so it CANNOT be bundled
//    and the cache is hard-capped. See ESVClient.
//

import Foundation

// MARK: - Translation

enum BibleTranslation: String, CaseIterable, Identifiable, Codable {
    case krv        // 개역한글 — bundled, public domain
    case esv        // ESV — fetched, licensed

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .krv: return "한"
        case .esv: return "영"
        }
    }

    var displayName: String {
        switch self {
        case .krv: return "개역한글"
        case .esv: return "ESV"
        }
    }

    /// Shown wherever the text is displayed — required for both.
    var attribution: String {
        switch self {
        case .krv: return "성경전서 개역한글판 · 대한성서공회"
        case .esv: return "ESV® Bible, © Crossway"
        }
    }

    var isBundled: Bool { self == .krv }

    var bookLabel: String {
        switch self {
        case .krv: return "시편"
        case .esv: return "Psalm"
        }
    }
}

// MARK: - Verse & chapter

struct BibleVerse: Identifiable, Hashable, Codable {
    let number: Int
    let text: String
    var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number = "v"
        case text = "t"
    }
}

struct BibleChapter: Identifiable, Hashable {
    let chapter: Int
    let verses: [BibleVerse]
    let translation: BibleTranslation
    var id: String { "\(translation.rawValue)-\(chapter)" }

    var verseCount: Int { verses.count }
}

// MARK: - Bundled file shape

struct BundledBook: Decodable {
    let book: String
    let bookEnglish: String
    let translation: String
    let translationName: String
    let attribution: String
    let chapters: [Chapter]

    struct Chapter: Decodable {
        let chapter: Int
        let verses: [BibleVerse]
    }
}

// MARK: - Psalms constants

enum Psalms {
    static let chapterCount = 150

    /// Wraps 1…150 so the daily advance never falls off either end.
    static func wrap(_ chapter: Int) -> Int {
        let m = (chapter - 1) % chapterCount
        return (m < 0 ? m + chapterCount : m) + 1
    }
}
