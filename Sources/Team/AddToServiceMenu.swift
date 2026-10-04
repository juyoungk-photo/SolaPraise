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
    @State private var note: String?

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
        _ = await team.appendSong(
            title: title, videoId: videoId, key: key,
            to: service, sheetId: sheetId
        )
    }
}
