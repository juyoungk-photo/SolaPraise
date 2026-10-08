//
//  PartAliases.swift
//  SolaPraise
//
//  Which part names mean the same job.
//
//  WHY: 반주 is a job; Piano is the instrument that does it. A sheet that
//  puts somebody in Piano has staffed 반주, and a screen that then shows
//  「반주 미지정」 in red beside 「성훈 Piano」 in green is not reporting a gap,
//  it is reporting that it does not understand its own schedule.
//
//  The same holds for 인도 / 인도자 / 리더, and for a sheet that spells a
//  column 반주자 where the chips say 반주.
//
//  One list, used by everything that compares two part names — reading a
//  chip, resolving which column to write, and deciding which parts a service
//  cannot happen without. They disagreed before this existed: reading matched
//  loosely, writing matched exactly, and a tap on 인도 asked for a column
//  named 인도 on a sheet whose column said 인도자.
//

import Foundation

enum PartAliases {

    /// Names that stand for the same job. Order matters only in that the
    /// first entry is the one shown when the app has to name the group
    /// itself.
    static let groups: [[String]] = [
        ["인도", "인도자", "리더", "lead", "leader", "worship leader"],
        ["반주", "반주자", "piano", "피아노", "건반", "keys", "keyboard"]
    ]

    /// Comparable form: spaces removed, lowercased.
    static func key(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "").lowercased()
    }

    /// Every name that means the same as this one, including itself.
    static func aliases(of name: String) -> [String] {
        let needle = key(name)
        guard let group = groups.first(where: { $0.contains(where: { key($0) == needle }) })
        else { return [name] }
        return group
    }

    /// Do these two names mean the same job?
    ///
    /// Containment as well as equality, because a sheet writes 반주자 where
    /// the chip says 반주 — but containment ONLY inside a group, so 보컬 and
    /// 보컬2 still compare as themselves and two unrelated parts that happen
    /// to share a syllable do not merge.
    static func matches(_ a: String, _ b: String) -> Bool {
        let left = key(a), right = key(b)
        if left == right || left.contains(right) || right.contains(left) { return true }
        let group = aliases(of: a).map(key)
        guard group.count > 1 else { return false }
        return group.contains { $0 == right || right.contains($0) || $0.contains(right) }
    }

    /// The parts a service cannot happen without.
    static func isCore(_ name: String) -> Bool {
        groups.contains { group in
            group.contains { matches($0, name) }
        }
    }
}
