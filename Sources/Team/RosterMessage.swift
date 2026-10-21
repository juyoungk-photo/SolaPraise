//
//  RosterMessage.swift
//  SolaPraise
//
//  배정표 보내기: a service's parts and who is on them, who has not answered,
//  and where to answer — as a message for the team's chat.
//
//  WHY: the team talks in a chat room, not in the app. A leader retyped the
//  roster there every week, and the people who had not answered were
//  chased one by one. One tap now says it all, with the sheet's link for
//  anyone without the app.
//
//  Pure, so the wording is checked (Tools/check-roster-message.swift).
//

import Foundation

enum RosterMessage {

    /// - parts: each part in the sheet's order, with whoever is on it ("" for nobody).
    /// - pending: who has not answered, by name.
    static func text(day: Date, title: String, time: String?, parts: [(part: String, who: String)],
                     pending: [String], link: URL?, calendar: Calendar = .current) -> String {
        var lines = ["\(Self.day(day, calendar: calendar)) \(title)" + (time.map { " \($0)" } ?? "")]
        let staffed = parts.map { "\($0.part) \($0.who.trimmingCharacters(in: .whitespaces).isEmpty ? "—" : $0.who)" }
        if !staffed.isEmpty { lines.append(staffed.joined(separator: " · ")) }
        let open = parts.filter { $0.who.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.part)
        if !open.isEmpty { lines.append("아직 비어 있는 파트: " + open.joined(separator: ", ")) }
        if !pending.isEmpty { lines.append("아직 응답 안 함: " + pending.joined(separator: ", ")) }
        if let link { lines.append("응답 · 배정은 팀 시트에서: \(link.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    /// 「11/1(일)」.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let d = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekday = ["일", "월", "화", "수", "목", "금", "토"][((d.weekday ?? 1) - 1) % 7]
        return "\(d.month ?? 0)/\(d.day ?? 0)(\(weekday))"
    }

    /// 「반주로」, 「인도로」, 「Keys로」, 「건반으로」 — 으로 after a final
    /// consonant other than ㄹ.
    static func withRo(_ word: String) -> String {
        guard let last = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return word + "로" }
        let final = (last.value - 0xAC00) % 28
        return word + (final == 0 || final == 8 ? "로" : "으로")
    }

    /// The parts a name is on in one service, by the sheet's cells —
    /// matched loosely, as the two tabs are typed by different people
    /// (the Schedule cell 「김은혜」, the roster 「은혜」).
    static func parts(of name: String, in assignments: [(part: String, cell: String)],
                      names: (String) -> [String]) -> [String] {
        let needle = name.replacingOccurrences(of: " ", with: "")
        guard !needle.isEmpty else { return [] }
        return assignments.filter { entry in
            names(entry.cell).contains { cell in
                let who = cell.replacingOccurrences(of: " ", with: "")
                if who == needle { return true }
                return min(who.count, needle.count) >= 2 && (who.contains(needle) || needle.contains(who))
            }
        }.map(\.part)
    }
}
