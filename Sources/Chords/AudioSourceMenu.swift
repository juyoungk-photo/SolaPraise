//
//  AudioSourceMenu.swift
//  SolaPraise
//
//  음원 찾기, shared wherever a song is named.
//

import SwiftUI

struct AudioSourceMenu<Label: View>: View {
    let title: String
    @ViewBuilder var label: Label

    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            Section("구매하면 분석할 수 있습니다") {
                ForEach(AudioSources.all) { source in
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
