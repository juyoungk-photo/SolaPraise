//
//  EpisodeDate.swift
//  SolaPraise
//
//  Which day an episode is FOR, read from its title.
//
//  WHY NOT THE UPLOAD DATE: both daily channels the app follows publish on a
//  different clock from the one they serve.
//
//  매일성경 uploads two or three days ahead, so "the newest upload" was
//  regularly the day after tomorrow's reading. It also interleaves book
//  introductions and 묵상 among the daily episodes, so stepping back one
//  upload is not stepping back one day.
//
//  코너스톤교회 모닝워십 goes out at six in the morning, but the upload
//  timestamp lands whenever the stream was processed — so a refresh at
//  breakfast kept answering with yesterday.
//
//  Both of them write the date they are for into the title, which is the one
//  thing in the feed that actually says which day an episode belongs to:
//
//      「2026년 10월 9일 | 매일성경」 기브아의 비극 [사사기 19:22-30]
//      [모닝워십] 수, 10.7.2026 항상 진실케, 내 맘을
//      2026_1001 | 어노인팅목요예배
//
//  This reads that. It is deliberately strict — a wrong date is worse than no
//  date, because no date falls back to the upload order while a wrong one
//  silently shows the wrong day — so a match has to look like a date and land
//  within a plausible window of now.
//

import Foundation

enum EpisodeDate {

    /// The day this title says it is for, or nil when it does not say.
    static func inTitle(_ title: String, now: Date = Date()) -> Date? {
        for pattern in patterns {
            guard let parsed = pattern.parse(title, now) else { continue }
            guard isPlausible(parsed, now: now) else { continue }
            return Calendar.current.startOfDay(for: parsed)
        }
        return nil
    }

    /// A schedule runs a few months either side of today. Anything outside
    /// that is a number that merely looked like a date — a chapter range, a
    /// view count, a year in a song title.
    private static func isPlausible(_ date: Date, now: Date) -> Bool {
        let days = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        return days > -400 && days < 120
    }

    // MARK: - Patterns

    private struct Pattern {
        let regex: String
        /// Maps the captured groups to (year, month, day). A nil year means
        /// the title did not give one.
        let build: ([Int]) -> (year: Int?, month: Int, day: Int)?

        func parse(_ title: String, _ now: Date) -> Date? {
            guard let match = firstMatch(regex, in: title) else { return nil }
            guard let parts = build(match) else { return nil }
            return makeDate(year: parts.year, month: parts.month, day: parts.day, now: now)
        }
    }

    private static let patterns: [Pattern] = [
        // 2026년 10월 9일
        Pattern(regex: "(\\d{4})\\s*년\\s*(\\d{1,2})\\s*월\\s*(\\d{1,2})\\s*일") {
            $0.count == 3 ? ($0[0], $0[1], $0[2]) : nil
        },
        // 10월 9일 — no year
        Pattern(regex: "(?<!\\d)(\\d{1,2})\\s*월\\s*(\\d{1,2})\\s*일") {
            $0.count == 2 ? (nil, $0[0], $0[1]) : nil
        },
        // 10.7.2026 or 10/7/2026
        Pattern(regex: "(?<!\\d)(\\d{1,2})[./](\\d{1,2})[./](\\d{4})(?!\\d)") {
            $0.count == 3 ? ($0[2], $0[0], $0[1]) : nil
        },
        // 2026-10-07, 2026.10.07, 2026_10_07
        Pattern(regex: "(?<!\\d)(\\d{4})[-._/](\\d{1,2})[-._/](\\d{1,2})(?!\\d)") {
            $0.count == 3 ? ($0[0], $0[1], $0[2]) : nil
        },
        // 2026_1001 / 20261001 — year then four digits of month and day.
        Pattern(regex: "(?<!\\d)(\\d{4})[_ ]?(\\d{2})(\\d{2})(?!\\d)") {
            $0.count == 3 ? ($0[0], $0[1], $0[2]) : nil
        },
        // 26.10.01 — two-digit year first. Last, because it is the most
        // easily confused with a chapter-and-verse range.
        Pattern(regex: "(?<!\\d)(\\d{2})\\.(\\d{1,2})\\.(\\d{1,2})(?!\\d)") {
            $0.count == 3 ? (2000 + $0[0], $0[1], $0[2]) : nil
        }
    ]

    // MARK: - Helpers

    private static func firstMatch(_ pattern: String, in text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        var groups: [Int] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text),
                  let value = Int(text[range]) else { return nil }
            groups.append(value)
        }
        return groups
    }

    private static func makeDate(year: Int?, month: Int, day: Int, now: Date) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let calendar = Calendar(identifier: .gregorian)

        guard let year else {
            // No year given. Take the reading nearest to now rather than
            // defaulting to this one and putting next January in the past.
            let thisYear = calendar.component(.year, from: now)
            let candidates = [thisYear, thisYear + 1, thisYear - 1].compactMap {
                calendar.date(from: DateComponents(year: $0, month: month, day: day))
            }
            return candidates.min {
                abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now))
            }
        }
        guard year > 2000, year < 2100 else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
