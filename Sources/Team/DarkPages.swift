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
