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
}
