//
//  ContiCaption.swift
//  SolaPraise
//
//  The line in the top-left corner of each page of a 콘티 made here:
//  「2026/10/18 주일2부 - 1. 곡 제목」 — the service, and where the song
//  falls in it.
//
//  WHY: a 콘티 printed or passed around loses its file name. A page on the
//  stand, or one that slid out of order, should still say which Sunday
//  and which song it is (Tools/check-conti-caption.swift).
//

import Foundation

enum ContiCaption {

    /// 「2026/10/18 주일2부 - 1. 곡 제목」; without an order, the song alone;
    /// without a song, the service alone.
    static func text(date: Date, service: String, order: Int? = nil, song: String? = nil,
                     calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let head = [day, serviceName(service)].filter { !$0.isEmpty }.joined(separator: " ")
        guard let song = song?.trimmingCharacters(in: .whitespaces), !song.isEmpty else { return head }
        return head + " - " + (order.map { "\($0). " } ?? "") + song
    }

    /// A service as a corner can carry it: 「주일 2부예배」 → 「주일2부」.
    /// 「예배」 at the end goes, and the space before a number — the way
    /// the team writes 「주일1부」 — and nothing else.
    static func serviceName(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("예배"), name.count > 2 { name = String(name.dropLast(2)) }
        name = name.replacingOccurrences(of: #"(?<=[가-힣])\s+(?=\d)"#, with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespaces)
    }
}
