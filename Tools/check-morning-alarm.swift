//
//  check-morning-alarm.swift
//  SolaPraise
//
//  Checks what the morning alarm plays for 모닝워십: the stream when it is
//  on, waiting while it is not yet, and the latest service only after
//  waiting has gone on too long.
//
//  WHY THIS EXISTS: every wrong answer here plays something at full volume
//  at six in the morning — yesterday's service while today's is about to
//  start, or a stream scheduled for tomorrow. None of them is an error.
//
//  Run:
//      swiftc -O -o /tmp/morningalarm \
//          Sources/Feed/EpisodeDate.swift Sources/Feed/DailySeries.swift \
//          Sources/Alarm/MorningWorshipPick.swift Tools/check-morning-alarm.swift
//      /tmp/morningalarm
//

import Foundation

@main
struct CheckMorningAlarm {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    static func main() {
        typealias C = MorningWorshipPick.Candidate
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 5, minute: 58))!
        let alarm = now.addingTimeInterval(-3 * 60)

        let yesterday = C(id: "mon", title: "[모닝워십] 월, 10.12.2026 「새 노래로」", broadcast: "none",
                          publishedAt: now.addingTimeInterval(-12 * 3600))
        let older = C(id: "fri", title: "[모닝워십] 금, 10.9.2026 「감사」", broadcast: "none",
                      publishedAt: now.addingTimeInterval(-6 * 3600))   // archived later, published later
        let sunday = C(id: "sun", title: "[2부예배] 10.11.2026 \"…\"", broadcast: "none",
                       publishedAt: now.addingTimeInterval(-3600))
        let scheduled = C(id: "today", title: "[모닝워십] 화, 10.13.2026", broadcast: "upcoming", publishedAt: nil)
        let onAir = C(id: "today", title: "[모닝워십] 화, 10.13.2026", broadcast: "live", publishedAt: nil)

        check("on air: the stream plays",
              MorningWorshipPick.decide([sunday, onAir, yesterday], waitingSince: alarm, now: now) == .live("today"))
        check("scheduled but not on air: wait, do not play yesterday's",
              MorningWorshipPick.decide([scheduled, yesterday], waitingSince: alarm, now: now) == .wait)
        check("nothing scheduled, just after the alarm: still wait",
              MorningWorshipPick.decide([sunday, yesterday], waitingSince: alarm, now: now) == .wait)

        let late = alarm.addingTimeInterval(MorningWorshipPick.longestWait + 1)
        let fallback = MorningWorshipPick.decide([sunday, older, yesterday, scheduled], waitingSince: alarm, now: late)
        check("waited too long: the latest 모닝워십 by its date, not the newest upload or a Sunday service",
              fallback == .recent("mon"), "got \(fallback)")
        check("a stream that is only scheduled is never the recording played",
              MorningWorshipPick.recent(in: [scheduled], now: now) == nil)
        check("no 모닝워십 at all: the newest finished video",
              MorningWorshipPick.recent(in: [sunday, C(id: "x", title: "공지", broadcast: "none",
                                                       publishedAt: now.addingTimeInterval(-9000))], now: now) == "sun")
        check("nothing at all after waiting: nothing",
              MorningWorshipPick.decide([], waitingSince: alarm, now: late) == .nothing)

        // Nothing to wait for: played at once.
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 21, minute: 30))!
        check("tried in the evening, nothing scheduled: the latest at once, no wait",
              MorningWorshipPick.decide([sunday, yesterday], waitingSince: evening, now: evening) == .recent("mon"))
        let todayDone = C(id: "tue", title: "[모닝워십] 화, 10.13.2026 「빛」", broadcast: "none",
                          publishedAt: now.addingTimeInterval(-600))
        check("today's service already up: it, at once",
              MorningWorshipPick.decide([todayDone, yesterday], waitingSince: now, now: now) == .recent("tue"))
        check("evening but a stream is scheduled: wait for it",
              MorningWorshipPick.decide([scheduled, yesterday], waitingSince: evening, now: evening) == .wait)

        print(failures == 0 ? "\nall morning alarm checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
