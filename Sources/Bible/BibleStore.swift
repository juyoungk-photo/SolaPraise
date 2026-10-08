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
    private let apiBible: APIBibleClient

    init(esvKeyProvider: @escaping @Sendable () -> String? = { AppSecrets.esvAPIKey }) {
        self.esv = ESVClient(keyProvider: esvKeyProvider)
        self.apiBible = APIBibleClient()
    }

    func chapter(_ number: Int, in translation: BibleTranslation) async throws -> BibleChapter {
        let n = Psalms.wrap(number)
        switch translation {
        case .krv:
            return BibleChapter(chapter: n, verses: try loadBundled(n), translation: .krv)
        case .esv:
            return BibleChapter(chapter: n, verses: try await esv.chapter(n), translation: .esv)
        case .extra:
            guard let version = ReadingSettings.extraVersion else {
                throw APIBibleClient.ClientError.missingKey
            }
            return BibleChapter(
                chapter: n,
                verses: try await apiBible.passage("Psalm \(n)", versionId: version.id),
                translation: .extra
            )
        }
    }

    /// Any passage outside the Psalms, which the bundle does not carry.
    func esvPassage(_ query: String) async throws -> [BibleVerse] {
        try await esv.passage(query)
    }

    /// The reader's chosen third translation, whatever their key allows.
    func extraPassage(_ query: String, versionId: String) async throws -> [BibleVerse] {
        try await apiBible.passage(query, versionId: versionId)
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
        static let apiBibleKey = "reading.apiBibleKey"
        static let youtubeKey = "app.youtubeAPIKey"
        static let teamSheetId = "team.sheetId"
        static let churchSheetId = "church.sheetId"
        static let extraVersion = "reading.extraVersion"
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

    /// The team's planning sheet. A pasted Sheets URL is reduced to its id.
    static var teamSheetId: String? {
        get { defaults.string(forKey: Keys.teamSheetId)?.trimmingCharacters(in: .whitespaces) }
        set { defaults.set(newValue, forKey: Keys.teamSheetId) }
    }

    /// The church's information sheet, read for 헌신찬양 and 설교제목.
    /// Separate from the team's sheet: a different document, owned by the
    /// office, and only ever read.
    static var churchSheetId: String? {
        get { defaults.string(forKey: Keys.churchSheetId)?.trimmingCharacters(in: .whitespaces) }
        set { defaults.set(newValue, forKey: Keys.churchSheetId) }
    }

    /// A YouTube API key typed in on this device, overriding the build's.
    /// Lets one person try the no-sign-in path without a rebuild.
    static var youtubeAPIKey: String? {
        get { defaults.string(forKey: Keys.youtubeKey)?.trimmingCharacters(in: .whitespaces) }
        set { defaults.set(newValue, forKey: Keys.youtubeKey) }
    }

    /// The reader's own API.Bible key. Device only, never committed.
    static var apiBibleKey: String? {
        get { defaults.string(forKey: Keys.apiBibleKey)?.trimmingCharacters(in: .whitespaces) }
        set { defaults.set(newValue, forKey: Keys.apiBibleKey) }
    }

    /// The one extra translation the reader has chosen from that key.
    ///
    /// One rather than many: the picker is a segmented control beside 개역한글
    /// and ESV, and a fourth option is already the point at which it stops
    /// being readable.
    static var extraVersion: APIBibleClient.Version? {
        get {
            guard let data = defaults.data(forKey: Keys.extraVersion) else { return nil }
            return try? JSONDecoder().decode(APIBibleClient.Version.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.extraVersion)
                return
            }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.extraVersion)
        }
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
