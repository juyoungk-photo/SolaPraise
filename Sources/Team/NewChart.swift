//
//  NewChart.swift
//  SolaPraise
//
//  A chart just put up for a song of a service — from 📎, or found and
//  imported with 「이 악보로 연주」 — is what the 콘티 takes from then on.
//
//  At once when nothing was chosen: the newest version is the default, and
//  a choice this device kept for an earlier chart is let go. When one was
//  chosen on purpose — ✓ on the sheet, or 「콘티에 넣기」 here — the person
//  is asked once, rather than the new chart quietly losing to it or
//  quietly overturning what the team agreed.
//

import Foundation

@MainActor
enum NewChart {

    /// The version chosen on purpose for the song before `fileId` came,
    /// named for the question; nil when the newest was simply taken.
    static func standing(team: TeamStore, service: TeamService, song: String, except fileId: String) -> String? {
        let charts = team.attachments(for: service, song: song).filter { $0.fileId != fileId }
        if let marked = charts.first(where: \.chosenForConti) {
            return marked.name
        }
        let scope = ContiChoice.scope(service)
        guard let id = ContiChoice.chosen(scope: scope, song: song), id != fileId else { return nil }
        // A version's id is its file, with the pages after 「#」 for a 콘티's.
        let file = id.split(separator: "#").first.map(String.init) ?? id
        if let chart = charts.first(where: { $0.fileId == file }) { return chart.name }
        if team.chartContis(for: service).contains(where: { $0.fileId == file }) { return "콘티의 쪽" }
        return nil
    }

    /// Nothing was chosen: the newest — this one — is the default, and a
    /// choice kept for a chart no longer among the versions goes.
    static func takeNewest(service: TeamService, song: String) {
        ContiChoice.choose(nil, scope: ContiChoice.scope(service), song: song)
    }

    /// The new chart in the 콘티: on this device, and on the sheet when the
    /// team had marked another there — or, `marked`, had marked one now
    /// gone, the pages joined into this one.
    static func makeDefault(_ chart: Attachment, team: TeamStore, service: TeamService, song: String,
                            sheetId: String?, marked: Bool? = nil) async -> String? {
        ContiChoice.choose(chart.fileId, scope: ContiChoice.scope(service), song: song)
        let marked = marked ?? team.attachments(for: service, song: song)
            .contains { $0.chosenForConti && $0.fileId != chart.fileId }
        guard marked, let sheetId else { return nil }
        return await team.chooseForConti(ScoreStandItem(attachment: chart, song: song, teamKey: nil),
                                         service: service, sheetId: sheetId)
    }
}
