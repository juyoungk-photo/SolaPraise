//
//  OfferingNote.swift
//  SolaPraise
//
//  헌금송: a song of the 순서 marked as the offering song, with who prays
//  the offering prayer — kept in the song's Notes cell on the team's sheet,
//  「헌금송 · 헌금기도: 이름」, beside whatever else the notes say.
//
//  WHY THE NOTES CELL: it is the team's, shared, and already read and
//  written per song. The team also marks it by writing 「헌금찬양」 in the
//  Order column, which is read too. The call said before the offering is
//  the church's own words and the same each week: a setting, not per song.
//
//  Pure, so what is read and written is checked without the app
//  (Tools/check-offering-note.swift).
//

import Foundation

enum OfferingNote {

    struct Parsed: Equatable {
        var isOffering: Bool
        /// Who prays the offering prayer: 「김선홍 형제님」.
        var prayer: String?
        /// The rest of the notes, as written.
        var rest: String?
    }

    /// The words a team marks it with. 「헌신찬양」 too: the song a church
    /// sings as the offering is taken, under that name in its 순서 — and,
    /// spaced 「헌신 찬양」, as people type it.
    static let markers = ["헌금송", "헌금찬양", "봉헌찬양", "봉헌송", "헌신찬양", "헌신 찬양"]

    /// The call before the offering, until a team writes its own (설정).
    static let defaultCall = "헌금을 드림은 모든 것이 주님께로부터 왔음을 감사하는 믿음의 행위입니다. 자원함과 기쁨으로 드리는 성도님의 헌금은 주님께 영광이 될 뿐만 아니라, 우리 교회가 예수님의 대사명을 감당할 수 있도록 돕는 우리의 아름다운 동역입니다."

    static let callKey = "offering.call"

    /// The call as set on this device, or the default.
    static var call: String {
        let set = UserDefaults.standard.string(forKey: callKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return set?.isEmpty == false ? set! : defaultCall
    }

    /// Compiled once: read for every 순서 line drawn.
    private static let prayerPattern = try? NSRegularExpression(pattern: #"헌금\s*기도\s*(?:자)?\s*[:：]?\s*([^·\n,/|]+)"#)

    static func parse(notes: String?, orderLabel: String? = nil) -> Parsed {
        var text = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let labelled = orderLabel.map { label in markers.contains { label.contains($0) } || label.contains("헌금") } ?? false
        var isOffering = labelled

        var prayer: String?
        if let regex = Self.prayerPattern,
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) {
            let name = text[range].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { prayer = name }
            text.removeSubrange(whole)
            isOffering = true
        }
        for marker in markers where text.contains(marker) {
            isOffering = true
            text = text.replacingOccurrences(of: marker, with: " ")
        }
        let rest = text
            .components(separatedBy: CharacterSet(charactersIn: "·\n"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,/|")) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return Parsed(isOffering: isOffering, prayer: prayer, rest: rest.isEmpty ? nil : rest)
    }

    /// The Notes cell for a song: 「헌금송 · 헌금기도: 이름 · the rest」, or
    /// just the rest when it is not the offering song. Nil when empty.
    static func notes(isOffering: Bool, prayer: String?, rest: String?) -> String? {
        let name = prayer?.trimmingCharacters(in: .whitespaces)
        let parts = [isOffering ? "헌금송" : nil,
                     isOffering && name?.isEmpty == false ? "헌금기도: \(name!)" : nil,
                     rest?.trimmingCharacters(in: .whitespaces)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
