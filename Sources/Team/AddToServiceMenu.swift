//
//  AddToServiceMenu.swift
//  SolaPraise
//
//  "이 곡을 콘티에" — from wherever the song is playing.
//
//  The decision that a song belongs in Sunday's set is made while listening
//  to it, not later in a spreadsheet. Everything between those two moments is
//  friction, and this removes it.
//

import SwiftUI

struct AddToServiceMenu<Label: View>: View {
    let title: String
    let videoId: String
    /// A key the app already knows — from a chart, or published by the team.
    var key: String?
    @ViewBuilder var label: Label

    @EnvironmentObject private var team: TeamStore

    var body: some View {
        let services = team.services.filter { !$0.isPast && !$0.isRehearsal }.prefix(8)
        if !services.isEmpty, TeamSheetSource.current != nil {
            Menu {
                ForEach(Array(services)) { service in
                    Button {
                        Task { await add(to: service) }
                    } label: {
                        Text(service.date.formatted(.dateTime.month().day().weekday())
                             + " " + service.title)
                    }
                }
            } label: {
                label
            }
        }
    }

    private func add(to service: TeamService) async {
        guard let sheetId = TeamSheetSource.current else { return }
        let name = service.date.formatted(.dateTime.month(.defaultDigits).day())
            + " " + service.title
        let result = await team.appendSong(
            title: title, videoId: videoId, key: key,
            to: service, sheetId: sheetId
        )
        // Said where the person is looking. The 콘티 is on another tab, and
        // an add with no visible result was being made again and again.
        switch result {
        case .added:
            Toast.shared.show("\(name) 콘티에 추가했습니다")
        case .alreadyThere:
            Toast.shared.show("이미 \(name) 콘티에 있습니다",
                              symbol: "info.circle.fill", tint: .blue)
        case .misplaced:
            Toast.shared.show("시트의 다른 칸에 들어갔습니다 — 예배 준비에서 확인하세요",
                              symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .failed(let message):
            Toast.shared.show("추가하지 못했습니다: \(message)",
                              symbol: "xmark.octagon.fill", tint: .red)
        }
    }
}
