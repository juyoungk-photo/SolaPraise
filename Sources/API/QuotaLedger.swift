//
//  QuotaLedger.swift
//  SolaPraise
//
//  YouTube Data API v3 quota accounting.
//
//  The default project allocation is 10,000 units/day, resetting at midnight
//  Pacific. Reads cost 1 unit, searches cost 100, and every write costs 50 —
//  so a careless search-per-keystroke UI would burn the whole day in 100
//  queries. This ledger records every call's cost before it goes out, exposes
//  the remaining budget to the UI, and refuses spends it can't afford.
//
//  The limit-marker strategy is ported from Video_Organizer
//  (camera_clip_organizer.py:11142), which learned it the hard way: when the
//  quota is gone the API returns a recognisable reason string, and the right
//  response is to degrade gracefully rather than surface a raw 403.
//

import Foundation
import SwiftUI

@MainActor
final class QuotaLedger: ObservableObject {

    // MARK: - Cost table (units per call)

    enum Cost: Int {
        case read       = 1     // playlists.list, playlistItems.list, videos.list, channels.list
        case search     = 100   // search.list
        case write      = 50    // playlistItems.insert/update/delete, playlists.insert
        case rss        = 0     // feeds/videos.xml — not an API call at all

        var label: String {
            switch self {
            case .read:   return "read"
            case .search: return "search"
            case .write:  return "write"
            case .rss:    return "rss"
            }
        }
    }

    // MARK: - Limits

    /// Google's default per-project allocation.
    static let dailyUnitLimit = 10_000

    /// Self-imposed ceiling on general searches per day. Deliberately visible
    /// in the UI: seeing the number fall is the discipline mechanism.
    static let dailySearchLimit = 100

    // MARK: - Published state

    @Published private(set) var unitsUsed: Int = 0
    @Published private(set) var searchesUsed: Int = 0
    @Published private(set) var day: String = ""

    // MARK: - Derived

    var unitsRemaining: Int { max(0, Self.dailyUnitLimit - unitsUsed) }
    var searchesRemaining: Int { max(0, Self.dailySearchLimit - searchesUsed) }
    var fractionUsed: Double { Double(unitsUsed) / Double(Self.dailyUnitLimit) }

    var canSearch: Bool {
        searchesRemaining > 0 && unitsRemaining >= Cost.search.rawValue
    }

    func canAfford(_ cost: Cost) -> Bool {
        unitsRemaining >= cost.rawValue
    }

    // MARK: - Persistence

    private let defaults: UserDefaults
    private enum Keys {
        static let day = "quota.day"
        static let units = "quota.units"
        static let searches = "quota.searches"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rollOverIfNeeded()
    }

    /// Quota resets at midnight Pacific, not local midnight — a Korea-morning
    /// session and the previous evening can land on the same quota day.
    private static func pacificDayString(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private func rollOverIfNeeded() {
        let today = Self.pacificDayString()
        let stored = defaults.string(forKey: Keys.day)
        if stored != today {
            defaults.set(today, forKey: Keys.day)
            defaults.set(0, forKey: Keys.units)
            defaults.set(0, forKey: Keys.searches)
            day = today
            unitsUsed = 0
            searchesUsed = 0
        } else {
            day = today
            unitsUsed = defaults.integer(forKey: Keys.units)
            searchesUsed = defaults.integer(forKey: Keys.searches)
        }
    }

    // MARK: - Recording

    /// Records a spend. Call this *before* issuing the request so an
    /// in-flight burst can't overshoot the ceiling.
    func record(_ cost: Cost, count: Int = 1) {
        guard cost != .rss else { return }
        rollOverIfNeeded()
        unitsUsed += cost.rawValue * count
        if cost == .search { searchesUsed += count }
        defaults.set(unitsUsed, forKey: Keys.units)
        defaults.set(searchesUsed, forKey: Keys.searches)
    }

    /// Called when the API itself reports exhaustion — trust the server over
    /// our local tally and pin the ledger to full.
    func markExhausted() {
        rollOverIfNeeded()
        unitsUsed = Self.dailyUnitLimit
        defaults.set(unitsUsed, forKey: Keys.units)
    }

    #if DEBUG
    /// Test hook: drain the budget to verify the refusal path.
    /// Must persist BOTH counters — writing searchesUsed to memory only means
    /// a freshly constructed ledger reloads 0 searches and reports a full
    /// search budget alongside exhausted units.
    func debugDrain() {
        rollOverIfNeeded()
        unitsUsed = Self.dailyUnitLimit
        searchesUsed = Self.dailySearchLimit
        defaults.set(unitsUsed, forKey: Keys.units)
        defaults.set(searchesUsed, forKey: Keys.searches)
    }
    func debugReset() {
        unitsUsed = 0; searchesUsed = 0
        defaults.set(0, forKey: Keys.units)
        defaults.set(0, forKey: Keys.searches)
    }
    #endif

    // MARK: - Limit detection

    /// Reason strings YouTube returns when the budget is gone.
    /// Ported from Video_Organizer's `_LIMIT_MARKERS`.
    private static let limitMarkers: Set<String> = [
        "quotaexceeded",
        "dailylimitexceeded",
        "ratelimitexceeded",
        "userratelimitexceeded",
        "uploadlimitexceeded",
        "servingLimitExceeded".lowercased()
    ]

    static func isLimitReason(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return limitMarkers.contains(reason)
    }
}
