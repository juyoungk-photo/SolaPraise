//
//  SheetMusicMenu.swift
//  SolaPraise
//
//  The 악보 찾기 menu, shared by every screen that names a song — and
//  shaped by the song: its team's own links and store first, then searches
//  that carry the title and the team rather than the raw upload title.
//

import SwiftUI

/// The menu's contents without the menu, so a screen that already has one
/// can fold the 악보 links into it instead of putting a second button beside
/// the first.
struct SheetMusicLinks: View {
    let title: String
    /// The channel the song came from, which names its team.
    var channel: String? = nil
    var published: [SheetMusicLink] = []
    /// Kept for callers; every link now opens in the app's 악보 finder.
    var open: ((URL) -> Void)? = nil
    /// The video the song is playing from, which finds its place on a 콘티.
    var videoId: String? = nil
    /// Where a chart found goes, when the caller knows: a song on a 콘티.
    var destination: ScoreDestination? = nil

    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @Environment(\.quotaLedger) private var quota: QuotaLedger!   // for clients only — see Unobserved
    @Environment(\.modelContext) private var modelContext

    /// Every link opens in the app's 악보 finder (ScoreFinder): the music
    /// goes on underneath, and the chart found opens on the stand —
    /// attached to the song on its 콘티 when it is on one.
    private func openURL(_ url: URL) {
        ScoreFinder.present(url: url, song: SheetMusicSources.plan(title: title, channel: channel).song,
                            destination: destination ?? found,
                            team: team, auth: auth, planning: planning, quota: quota, context: modelContext)
    }

    /// This song on the nearest upcoming 콘티: by its video, else by title.
    private var found: ScoreDestination? {
        for service in team.services.filter({ !$0.isPast }).sorted(by: { $0.date < $1.date }) {
            let songs = team.plan(for: service).filter { $0.kind == .song }
            if let item = songs.first(where: { videoId != nil && $0.videoId == videoId })
                ?? songs.first(where: { PlanSongTitle.sameSong($0.title, title) }) {
                return ScoreDestination(service: service, song: item.title, key: item.key)
            }
        }
        return nil
    }

    /// Top to bottom: 악보 검색 for this song, then the official chart when
    /// there is one, then the big English-language catalogues. The search
    /// is what is used most; the catalogues rarely carry Korean songs.
    var body: some View {
        let plan = SheetMusicSources.plan(title: title, channel: channel)
        Section("「\(plan.song)」 \(plan.context)") {
            Button {
                if let url = plan.searchURL { openURL(url) }
            } label: {
                Label("악보 검색", systemImage: "magnifyingglass")
            }
            Button {
                if let url = plan.imageSearchURL { openURL(url) }
            } label: {
                Label("악보 이미지 (큰 사이즈)", systemImage: "photo")
            }
            ForEach(SheetMusicSources.shops) { shop in
                Button {
                    if let url = plan.url(for: shop) { openURL(url) }
                } label: {
                    Text(shop.name)
                }
            }
        }
        if !published.isEmpty {
            Section("이 팀이 올린 악보") {
                ForEach(published) { link in
                    Button(link.label) { openURL(link.url) }
                }
            }
        }
        if let publisher = plan.publisher {
            Section("\(publisher.name) 공식 악보") {
                Button {
                    if let url = plan.url(for: publisher.store) { openURL(url) }
                } label: {
                    Label(publisher.store.name, systemImage: "checkmark.seal")
                }
            }
        }
        // The big catalogues, searched on their own pages — English title
        // when the upload carries one.
        Section("악보 스토어") {
            ForEach(SheetMusicSources.stores) { store in
                Button {
                    if let url = plan.url(for: store) { openURL(url) }
                } label: {
                    Label(store.name, systemImage: "books.vertical")
                }
            }
        }
    }
}

struct SheetMusicMenu<Label: View>: View {
    let title: String
    var channel: String? = nil
    /// Links the channel published itself, which outrank any search.
    var published: [SheetMusicLink] = []
    var open: ((URL) -> Void)? = nil
    var videoId: String? = nil
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            SheetMusicLinks(title: title, channel: channel, published: published, open: open, videoId: videoId)
        } label: {
            label
        }
        // As written, wherever the button sits: iOS otherwise turns a menu
        // upside down when it opens upward from the bottom of the screen.
        .menuOrder(.fixed)
    }
}
