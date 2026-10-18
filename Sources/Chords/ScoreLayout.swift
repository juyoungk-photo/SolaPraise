//
//  ScoreLayout.swift
//  SolaPraise
//
//  Where each transposed chord goes on the page, and how big — computed
//  once and used by both the stand's preview and the PDF export, so what a
//  reader checked on screen is exactly what the file contains.
//
//  WHY IT IS ITS OWN STEP: the first version sized every replacement from
//  its own box and drew it there. On a dense chart that broke two ways, both
//  reported from real use: a replacement longer than the original — G → G#,
//  C → Db/F — ran over the next chord, and its white patch ate the start of
//  the neighbour. So each chord is now given the room up to the next chord
//  on its line, and shrinks (to a floor) rather than overlapping.
//

import Foundation
import UIKit

/// One chord on a page, as the reader may have adjusted it.
///
/// Spelled in the SCORE's key, so a transposition is always computed from
/// what is printed and never compounded from an earlier one.
struct ScoreChord: Identifiable, Codable, Equatable {
    var id = UUID()
    var original: String
    /// Normalised page coordinates, origin top-left: where it was found.
    var box: CGRect
    /// Normalised drag the reader applied, if any.
    var offset: CGSize = .zero
    /// Placed by hand over a chord recognition missed. Its patch covers
    /// whatever is printed under it; there is no separate original to erase.
    var userAdded = false
    /// Its text corrected by hand. Drawn even in the printed key: the
    /// printed symbol under it is the one that was wrong. Optional, so
    /// chords kept before it existed still read.
    var corrected: Bool?

    /// Where it is drawn: the found box, moved by the reader's drag.
    var placed: CGRect { box.offsetBy(dx: offset.width, dy: offset.height) }
}

enum ScoreLayout {

    struct Label: Identifiable {
        let id: UUID
        let text: String
        /// Points in the page's size. White, then the text over it.
        let patch: CGRect
        /// Where the printed original sits, to be painted out — nil for a
        /// chord added by hand, which covers itself.
        let cover: CGRect?
        let fontSize: CGFloat
        let textOrigin: CGPoint
    }

    /// Smallest share of the page's chord size a replacement may shrink to
    /// before it is allowed to run into its neighbour instead.
    static let minimumShrink: CGFloat = 0.55

    /// The labels for one page.
    ///
    /// - chordHeight: the page's chord height, normalised (median of found).
    /// - scale: the reader's size setting, 1 = the printed size.
    /// - alwaysDraw: draw every chord even with no transposition — for edit
    ///   mode. A chord moved, added or corrected by hand is drawn anyway.
    static func labels(chords: [ScoreChord], chordHeight: CGFloat, shift: Int, useFlats: Bool?,
                       scale: CGFloat, alwaysDraw: Bool = false, in size: CGSize) -> [Label] {
        // A size chosen for the chords redraws them all, in the printed key
        // too: the clean, larger symbols are what a reader wanted from it —
        // on the stand, and printed. At the printed size, the page as printed.
        let alwaysDraw = alwaysDraw || resized(scale)
        let transposing = shift % 12 != 0
        let base = max(6, chordHeight * size.height / 0.96) * scale
        let gap = base * 0.3

        // Lines, by where each chord is drawn now, left to right.
        let drawn = chords.filter {
            alwaysDraw || transposing || $0.userAdded || $0.corrected == true || $0.offset != .zero
        }
        let sorted = drawn.sorted { $0.placed.minX < $1.placed.minX }

        var out: [Label] = []
        for chord in sorted {
            let text = (transposing ? ScoreTransposer.symbol(chord.original, by: shift, useFlats: useFlats) : nil)
                ?? chord.original
            let place = chord.placed
            let x = place.minX * size.width
            let midY = place.midY * size.height

            // Room up to the next chord on the same line.
            let next = sorted.first { other in
                other.id != chord.id
                    && other.placed.minX > place.minX
                    && abs(other.placed.midY - place.midY) < max(place.height, chordHeight) * 0.6
            }
            let room = next.map { $0.placed.minX * size.width - x - gap } ?? (size.width - x - gap)

            var fontSize = base
            var width = measure(text, size: fontSize)
            if width > room {
                fontSize = max(base * minimumShrink, base * room / width)
                width = measure(text, size: fontSize)
            }

            // The patch covers the new text, and at least the old symbol —
            // a short replacement must still hide a longer original.
            let originalWidth = chord.userAdded ? 0 : chord.box.width * size.width
            let pad = fontSize * 0.12
            let height = fontSize * 1.1
            let patch = CGRect(x: x - pad, y: midY - height / 2,
                               width: max(width, originalWidth) + pad * 2, height: height)

            let cover: CGRect? = chord.userAdded ? nil : {
                let original = CGRect(x: chord.box.minX * size.width, y: chord.box.minY * size.height,
                                      width: chord.box.width * size.width, height: chord.box.height * size.height)
                return original.insetBy(dx: -original.height * 0.12, dy: -original.height * 0.15)
            }()

            let lineHeight = UIFont.boldSystemFont(ofSize: fontSize).lineHeight
            out.append(Label(id: chord.id, text: text, patch: patch, cover: cover,
                             fontSize: fontSize,
                             textOrigin: CGPoint(x: x, y: midY - lineHeight / 2)))
        }
        return out
    }

    /// The chord size changed from the printed one (the stand's A buttons).
    static func resized(_ scale: CGFloat) -> Bool { abs(scale - 1) > 0.001 }

    static func measure(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: size)]).width
    }

    /// Draws labels into a context of the page's size: every cover first,
    /// then every patch and its text, so no patch erases another's text.
    static func draw(_ labels: [Label], in context: CGContext) {
        context.setFillColor(UIColor.white.cgColor)
        for label in labels { if let cover = label.cover { context.fill(cover) } }
        for label in labels {
            context.setFillColor(UIColor.white.cgColor)
            context.fill(label.patch)
            (label.text as NSString).draw(
                at: label.textOrigin,
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: label.fontSize),
                                 .foregroundColor: UIColor.black])
        }
    }
}
