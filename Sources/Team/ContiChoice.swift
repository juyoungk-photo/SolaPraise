//
//  ContiChoice.swift
//  SolaPraise
//
//  Which of a song's chart versions goes into the service's 콘티.
//
//  WHY: a song collects versions — the 콘티's pages, a chart in another
//  key, a lead sheet — and the stand lets them be compared side by side.
//  Comparing is looking; it must not decide what is printed. So the choice
//  is made on purpose (「콘티에 넣기」), shown on its chip, and is what
//  전체 악보 and every 콘티 made here use. Until one is chosen, the newest.
//
//  Kept on this device, by service and song.
//

import Foundation

enum ContiChoice {

    /// The service a choice belongs to: its day and name.
    static func scope(_ service: TeamService) -> String {
        TeamSheet.dateFormatter.string(from: service.date) + "|" + service.title
    }

    static func chosen(scope: String, song: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope, song))
    }

    static func choose(_ id: String?, scope: String, song: String) {
        UserDefaults.standard.set(id, forKey: key(scope, song))
    }

    /// The version the 콘티 takes: the one the team marked on the sheet;
    /// else the one chosen on this device (a choice the sheet could not
    /// take — an earlier service's chart, a 콘티's pages); else the newest
    /// — `versions` come newest first.
    static func pick(_ versions: [ScoreStandItem], scope: String, song: String) -> ScoreStandItem? {
        if let marked = versions.first(where: { $0.attachment.chosenForConti && $0.pages == nil && $0.earlierDay == nil }) {
            return marked
        }
        let id = chosen(scope: scope, song: song)
        return versions.first { $0.id == id } ?? versions.first
    }

    /// By the song, not the 순서's long title: a title tidied on the sheet
    /// keeps its choice.
    private static func key(_ scope: String, _ song: String) -> String {
        "conti.choice.\(scope)|\(PlanSongTitle.split(song).title)"
    }
}
