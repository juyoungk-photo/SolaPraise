//
//  AppSecrets.swift
//  SolaPraise
//
//  The app's own YouTube API key, for readers who never sign in.
//
//  WHY: almost nothing here needs a Google account. Feeds, search, playback,
//  the readers, chord detection and 악보 all work from public data. Only two
//  things need OAuth — listing your OWN playlists, and writing to them — and
//  on a worship team that is one or two people, not everyone.
//
//  Without this, sharing the app meant adding every teammate to the OAuth
//  consent screen by hand, capped at 100, with a 7-day token expiry and an
//  "unverified app" warning each time. With it, they install and use it.
//
//  The key is read from the build, not committed: Secrets.xcconfig is
//  gitignored, and an absent key simply means the app behaves as it did
//  before — sign-in required.
//

import Foundation

enum AppSecrets {

    /// Build-time key, or one typed into Settings on this device.
    ///
    /// A key shipped in a binary can be extracted, so restrict it to this
    /// bundle id in the Cloud Console. That makes a lifted key useless
    /// anywhere else, which is the protection that actually applies here —
    /// obscurity is not one.
    static var youtubeAPIKey: String? {
        if let stored = ReadingSettings.youtubeAPIKey, !stored.isEmpty { return stored }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "YouTubeAPIKey") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // An unset xcconfig variable arrives as the literal placeholder.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    static var hasYouTubeAPIKey: Bool { youtubeAPIKey != nil }

    /// The ESV key, shipped so a teammate does not have to get their own.
    ///
    /// Crossway licenses per application, not per reader, so one key for the
    /// app is the right shape — and the alternative is every member
    /// registering at api.esv.org before they can read a verse in English.
    static var esvAPIKey: String? {
        if let stored = ReadingSettings.esvAPIKey, !stored.isEmpty { return stored }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ESVAPIKey") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// The team's sheet, shipped with the build.
    ///
    /// Without this every teammate would paste the same URL into the same
    /// box on their own device — a setup step with one correct answer, asked
    /// of everyone. It is not a secret: who can read the sheet is decided by
    /// Google's sharing, not by whether the id is guessable. It still lives
    /// in the gitignored xcconfig, because it is the team's document and does
    /// not belong in a repository.
    /// The church's information sheet, shipped with the build like the
    /// team's. Read-only, and not a secret for the same reason: Google's
    /// sharing decides who can open it.
    static var churchSheetId: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ChurchSheetId") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    static var teamSheetId: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TeamSheetId") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

// MARK: - Which sheet this device uses

enum TeamSheetSource {
    /// A sheet typed in on this device wins over the build's, so one person
    /// can point at a different sheet — a second team, or a test copy —
    /// without a rebuild for everyone.
    static var current: String? {
        if let local = ReadingSettings.teamSheetId, !local.isEmpty { return local }
        return AppSecrets.teamSheetId
    }

    static var isFromBuild: Bool {
        (ReadingSettings.teamSheetId?.isEmpty ?? true) && AppSecrets.teamSheetId != nil
    }
}

