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

    @Environment(\.openURL) private var openURL

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
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            SheetMusicLinks(title: title, channel: channel, published: published)
        } label: {
            label
        }
        // As written, wherever the button sits: iOS otherwise turns a menu
        // upside down when it opens upward from the bottom of the screen.
        .menuOrder(.fixed)
    }
}
