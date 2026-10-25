//
//  DarkPages.swift
//  SolaPraise
//
//  악보 어둡게 보기 (베타): the chart's page shown light on black — its
//  notes, words and chords white on a dark stand, as the 코드표 already is.
//
//  The page as drawn — the chart, the chords laid on it, drawings — is
//  inverted, then its hues turned half round, so a red mark stays red
//  and a blue chord blue while black becomes white. On screen only: a
//  PDF, a photo, a print stay as the page is.
//

import SwiftUI

enum DarkPages {
    static let key = "score.darkPages"
}

struct DarkPage: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.colorInvert().hueRotation(.degrees(180))
        } else {
            content
        }
    }
}

/// 🌙 on the stand's header: 악보 어둡게 보기, on and off, where it is
/// seen. It was in 설정 and at the foot of the 저장·공유 menu, and could
/// not be found.
struct DarkPagesButton: View {
    @AppStorage(DarkPages.key) private var on = false

    var body: some View {
        Button { on.toggle() } label: {
            Image(systemName: on ? "moon.fill" : "moon")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 30)
                .background(on ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(on ? "악보 밝게 보기" : "악보 어둡게 보기 (베타)")
    }
}
