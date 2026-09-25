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
    /// The width a card wants.
    ///
    /// A YouTube medium thumbnail is 320pt wide, so anything past about
    /// 230 is upscaling. 165 is the narrowest that still fits two lines of a
    /// Korean title without truncating most of it, and it puts 5 across a
    /// portrait iPad rather than 4 oversized ones.
    static let idealCardWidth: CGFloat = 165
    static let spacing: CGFloat = 12

    /// Adaptive columns: 2 on a phone, 3–5 across iPad sizes and split views,
    /// decided by the space actually available rather than by device type —
    /// an iPad in a narrow split view deserves the phone layout.
    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: idealCardWidth, maximum: 230), spacing: spacing)]
    }
}
