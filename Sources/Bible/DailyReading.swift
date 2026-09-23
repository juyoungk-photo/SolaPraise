//
//  DailyReading.swift
//  SolaPraise
//
//  Which psalm today, and whether the full-screen gate is still owed.
//
//  Reading ahead carries forward: the daily advance moves one on from wherever
//  you actually stopped, not from a fixed calendar slot. Reading five psalms
//  on Sunday means Monday starts after those five, which is what "keep
//  reading" should mean.
//

import Foundation
import SwiftUI

@MainActor
final class DailyReading: ObservableObject {

    @Published private(set) var chapter: Int
    @Published var translation: BibleTranslation
    @Published private(set) var readChapters: Set<Int>

    init() {
        self.chapter = ReadingSettings.currentChapter
        self.translation = ReadingSettings.translation
        self.readChapters = ReadingSettings.readChapters
        advanceIfNewDay()
        #if DEBUG
        if let forced = DebugHarness.psalm { setChapter(forced) }
        if let t = DebugHarness.translation, let parsed = BibleTranslation(rawValue: t) {
            setTranslation(parsed)
        }
        if DebugHarness.forceReadingGate { ReadingSettings.lastGateDay = nil }
        if DebugHarness.skipReadingGate { ReadingSettings.lastGateDay = ReadingSettings.todayKey() }
        if let through = DebugHarness.seedReadThrough {
            // Scattered rather than contiguous, so the grid shows a realistic mix.
            let seeded = Set((1...max(1, through)).filter { $0 % 3 != 0 })
            readChapters = seeded
            ReadingSettings.readChapters = seeded
        }
        #endif
    }

    // MARK: - Daily advance

    /// The reading schedule, anchored to a fixed date.
    ///
    /// 2026-09-23 (수) is 시편 72편; every day after advances by one and wraps
    /// at 150. Anchoring beats incrementing a stored counter: a missed day, a
    /// reinstall, or a wiped store can no longer drift the schedule out of
    /// step with the rest of the team.
    private static let anchorDay = DateComponents(year: 2026, month: 9, day: 23)
    private static let anchorChapter = 72

    static func scheduledChapter(on date: Date = Date()) -> Int {
        let calendar = Calendar.current
        guard let anchor = calendar.date(from: anchorDay) else { return anchorChapter }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: anchor),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        return Psalms.wrap(anchorChapter + days)
    }

    /// Snaps to the scheduled psalm once per calendar day. Navigating away
    /// within the day is free; tomorrow returns to the schedule.
    func advanceIfNewDay(_ now: Date = Date()) {
        let today = ReadingSettings.todayKey(now)
        guard ReadingSettings.lastAdvancedDay != today else { return }
        setChapter(Self.scheduledChapter(on: now))
        ReadingSettings.lastAdvancedDay = today
    }

    // MARK: - Gate

    /// True until the full-screen reading has been shown once today.
    var isGateOwed: Bool {
        ReadingSettings.lastGateDay != ReadingSettings.todayKey()
    }

    func markGateShown() {
        ReadingSettings.lastGateDay = ReadingSettings.todayKey()
    }

    // MARK: - Navigation

    func next() { setChapter(Psalms.wrap(chapter + 1)) }
    func previous() { setChapter(Psalms.wrap(chapter - 1)) }

    func setChapter(_ n: Int) {
        let wrapped = Psalms.wrap(n)
        chapter = wrapped
        ReadingSettings.currentChapter = wrapped
    }

    func setTranslation(_ t: BibleTranslation) {
        translation = t
        ReadingSettings.translation = t
    }

    // MARK: - Read state

    var isCurrentRead: Bool { readChapters.contains(chapter) }

    func markRead() {
        readChapters.insert(chapter)
        ReadingSettings.readChapters = readChapters
    }

    func unmarkRead() {
        readChapters.remove(chapter)
        ReadingSettings.readChapters = readChapters
    }

    /// e.g. "시편 23편" / "Psalm 23"
    func title(for t: BibleTranslation) -> String {
        switch t {
        case .krv: return "시편 \(chapter)편"
        case .esv: return "Psalm \(chapter)"
        }
    }
}
