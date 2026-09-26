//
//  BibleStore.swift
//  SolaPraise
//
//  Serves a psalm in either translation: 개역한글 straight from the bundle,
//  ESV through Crossway's API.
//

import Foundation

@MainActor
final class BibleStore: ObservableObject {

    private var bundled: [Int: [BibleVerse]] = [:]
    private var bundledLoaded = false
    private let esv: ESVClient

    init(esvKeyProvider: @escaping @Sendable () -> String? = { ReadingSettings.esvAPIKey }) {
        self.esv = ESVClient(keyProvider: esvKeyProvider)
    }

    func chapter(_ number: Int, in translation: BibleTranslation) async throws -> BibleChapter {
        let n = Psalms.wrap(number)
        switch translation {
        case .krv:
            return BibleChapter(chapter: n, verses: try loadBundled(n), translation: .krv)
        case .esv:
            return BibleChapter(chapter: n, verses: try await esv.chapter(n), translation: .esv)
        }
    }

    /// Any passage outside the Psalms, which the bundle does not carry.
    func esvPassage(_ query: String) async throws -> [BibleVerse] {
        try await esv.passage(query)
    }

    // MARK: - Bundled 개역한글

    enum BundleError: LocalizedError {
        case missingResource, missingChapter(Int)
        var errorDescription: String? {
            switch self {
            case .missingResource:   return "The bundled 개역한글 text is missing from the app."
            case .missingChapter(let n): return "시편 \(n)편을 찾을 수 없습니다."
            }
        }
    }

    private func loadBundled(_ number: Int) throws -> [BibleVerse] {
        try loadBundledIfNeeded()
        guard let verses = bundled[number] else { throw BundleError.missingChapter(number) }
        return verses
    }

    private func loadBundledIfNeeded() throws {
        guard !bundledLoaded else { return }
        guard let url = Bundle.main.url(forResource: "psalms-krv", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw BundleError.missingResource
        }
        let book = try JSONDecoder().decode(BundledBook.self, from: data)
        for chapter in book.chapters {
            bundled[chapter.chapter] = chapter.verses
        }
        bundledLoaded = true
    }
}

// MARK: - Settings storage

/// Small UserDefaults-backed settings for the reading feature. Kept out of
/// SwiftData deliberately: the daily gate has to decide what to show during
/// launch, before any model context work.
enum ReadingSettings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let esvKey = "reading.esvAPIKey"
        static let currentChapter = "reading.currentChapter"
        static let lastAdvancedDay = "reading.lastAdvancedDay"
        static let lastGateDay = "reading.lastGateDay"
        static let readChapters = "reading.readChapters"
        static let translation = "reading.translation"
        static let notificationsOn = "reading.notificationsOn"
        static let notifyHour = "reading.notifyHour"
        static let notifyMinute = "reading.notifyMinute"
        static let appearance = "app.appearance"
    }

    /// The user's own Crossway key. Stored on device only, never committed.
    static var esvAPIKey: String? {
        get { defaults.string(forKey: Keys.esvKey)?.trimmingCharacters(in: .whitespaces) }
        set { defaults.set(newValue, forKey: Keys.esvKey) }
    }

    static var currentChapter: Int {
        get { max(1, min(Psalms.chapterCount, defaults.object(forKey: Keys.currentChapter) as? Int ?? 1)) }
        set { defaults.set(Psalms.wrap(newValue), forKey: Keys.currentChapter) }
    }

    static var lastAdvancedDay: String? {
        get { defaults.string(forKey: Keys.lastAdvancedDay) }
        set { defaults.set(newValue, forKey: Keys.lastAdvancedDay) }
    }

    static var lastGateDay: String? {
        get { defaults.string(forKey: Keys.lastGateDay) }
        set { defaults.set(newValue, forKey: Keys.lastGateDay) }
    }

    static var readChapters: Set<Int> {
        get { Set(defaults.array(forKey: Keys.readChapters) as? [Int] ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.readChapters) }
    }

    static var translation: BibleTranslation {
        get { BibleTranslation(rawValue: defaults.string(forKey: Keys.translation) ?? "") ?? .krv }
        set { defaults.set(newValue.rawValue, forKey: Keys.translation) }
    }

    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: Keys.notificationsOn) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.notificationsOn) }
    }

    static var notifyHour: Int {
        get { defaults.object(forKey: Keys.notifyHour) as? Int ?? 6 }
        set { defaults.set(newValue, forKey: Keys.notifyHour) }
    }

    static var notifyMinute: Int {
        get { defaults.object(forKey: Keys.notifyMinute) as? Int ?? 30 }
        set { defaults.set(newValue, forKey: Keys.notifyMinute) }
    }

    /// 시스템 / 밝게 / 어둡게.
    ///
    /// Defaults to following the system, which is both the least surprising
    /// choice and the one that already gives a dark phone a dark app.
    static var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    static func todayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}


import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "시스템"
        case .light:  return "밝게"
        case .dark:   return "어둡게"
        }
    }

    /// nil hands control back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
