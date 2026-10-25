//
//  PrintLayout.swift
//  SolaPraise
//
//  A PDF page as paper: each chart's page — caption, notice and the chart
//  together — fitted whole onto one sheet of the paper the place uses,
//  across the middle and from the top, inside a margin a printer can
//  print to.
//
//  WHY: the pages came out at the chart's own size — a PDF's, or 595 pt
//  across and as tall as a photo happened to be — with the notice making
//  the first page taller still. A printer shrank, cropped or split each
//  its own way. On paper, every page prints as one sheet.
//
//  Pure, so Tools/check-print-layout.swift runs it.
//

import Foundation
import CoreGraphics

enum PrintLayout {
    static let letter = CGSize(width: 612, height: 792)
    static let a4 = CGSize(width: 595.28, height: 841.89)
    /// A quarter of an inch: inside what a printer prints, and little else.
    static let margin: CGFloat = 18

    /// Letter where it is the paper — the United States, Canada, Mexico,
    /// the Philippines — A4 everywhere else.
    static func paper(region: String?) -> CGSize {
        ["US", "CA", "MX", "PH"].contains(region ?? "") ? letter : a4
    }

    /// The sheet for content of this shape: turned when it is wider than tall.
    static func sheet(for content: CGSize, paper: CGSize) -> CGSize {
        content.width > content.height ? CGSize(width: paper.height, height: paper.width) : paper
    }

    /// Where the content goes on the sheet: as large as fits inside the
    /// margin, keeping its shape, across the middle, from the top.
    static func place(_ content: CGSize, on sheet: CGSize, margin: CGFloat = margin) -> CGRect {
        let room = CGSize(width: sheet.width - margin * 2, height: sheet.height - margin * 2)
        guard content.width > 0, content.height > 0, room.width > 0, room.height > 0 else {
            return CGRect(origin: CGPoint(x: margin, y: margin), size: .zero)
        }
        let scale = min(room.width / content.width, room.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (sheet.width - size.width) / 2, y: margin, width: size.width, height: size.height)
    }
}
