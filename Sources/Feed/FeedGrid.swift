//
//  FeedGrid.swift
//  SolaPraise
//
//  One definition of how wide a video card should be.
//
//  Every grid was two fixed columns, which is right on a phone and wrong
//  everywhere else: on an iPad each card grew to roughly 350pt, so a
//  thumbnail meant for a 170pt tile was blown up to twice its size and four
//  videos filled the screen. Cards should stay about the size they were
//  designed at and the column count should follow the width.
//

import SwiftUI

enum FeedGrid {
    /// The width a card wants. Below this it gets cramped; much above it the
    /// thumbnail is being upscaled past its own resolution.
    static let idealCardWidth: CGFloat = 190
    static let spacing: CGFloat = 12

    /// Adaptive columns: 2 on a phone, 3–5 across iPad sizes and split views,
    /// decided by the space actually available rather than by device type —
    /// an iPad in a narrow split view deserves the phone layout.
    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: idealCardWidth, maximum: 280), spacing: spacing)]
    }
}
