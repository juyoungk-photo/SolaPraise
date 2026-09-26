//
//  SheetMusicMenu.swift
//  SolaPraise
//
//  The 악보 찾기 menu, shared by every screen that names a song.
//

import SwiftUI

struct SheetMusicMenu<Label: View>: View {
    let title: String
    /// Links the channel published itself, which outrank any search.
    var published: [SheetMusicLink] = []
    @ViewBuilder var label: Label

    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            if !published.isEmpty {
                Section("이 팀이 올린 링크") {
                    ForEach(published) { link in
                        Button(link.label) { openURL(link.url) }
                    }
                }
            }
            Section(published.isEmpty ? "" : "검색") {
                ForEach(SheetMusicSources.all) { source in
                    Button {
                        if let url = source.url(for: title) { openURL(url) }
                    } label: {
                        Text(source.name)
                    }
                }
            }
        } label: {
            label
        }
    }
}
