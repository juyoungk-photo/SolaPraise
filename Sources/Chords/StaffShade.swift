//
//  StaffShade.swift
//  SolaPraise
//
//  What 오선·음표 밝기 shades: each staff and the ink joined to it — note
//  heads, stems, beams, ties, a ledger note on its stem, a fifth line the
//  finder missed, held to the rest by the bar lines and the clef — pixel
//  by pixel, and nothing that stands apart from it. Words and chords are
//  printed clear of the staff, so they are never reached, even where a
//  stem rises level with a chord beside it.
//
//  It was rows: first a fixed reach, three line spacings below the
//  staff, with Vision cutting the words back out — a hymn sets its lyrics
//  closer than that, and 「주 께 드 리 네」 came out half grey — then every
//  row the staff's ink reached, which greyed the foot of a chord printed
//  level with the top of a stem.
//
//  The page's own pixels, top-left origin, ink being anything darker than
//  a light grey. CoreGraphics only, so Tools/check-staff-shade.swift runs it
//  on a Mac.
//

import Foundation
import CoreGraphics

enum StaffShade {
    /// How far from the lines the ink is followed, in line spacings: a low
    /// note's ledger lines below, a high one's above.
    static let reachBelow: CGFloat = 4
    static let reachAbove: CGFloat = 3

    /// 255 where the page is staff or ink joined to it — and two pixels
    /// round it, for the soft edge a scan, a JPEG or an enlarged photo
    /// leaves — 0 elsewhere. Row by
    /// row, `width` to a row. `staves` are the line rects as the finder
    /// gives them, normalised: four lines or five.
    static func mask(gray: [UInt8], width: Int, height: Int, staves: [CGRect]) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        guard width > 2, height > 2, gray.count >= width * height, !staves.isEmpty else { return mask }
        // Lighter than a word's ink counts: a hymnal's staff lines are
        // printed grey. Words and chords stand on white, so none is joined.
        func inked(_ i: Int) -> Bool { gray[i] < 200 }

        let h = CGFloat(height)
        var stack: [Int] = []
        for staff in staves {
            let top = Int(staff.minY * h), bottom = Int(staff.maxY * h)
            guard bottom > top, top >= 0, bottom < height else { continue }
            let space = CGFloat(max(1, (bottom - top) / 4))
            let lowest = max(0, top - Int(space * reachAbove))
            let highest = min(height - 1, bottom + Int(space * reachBelow))

            // Seeds: the ink between the outer lines — lines, clef, notes.
            for y in top...bottom {
                for x in 0..<width where inked(y * width + x) && mask[y * width + x] == 0 {
                    mask[y * width + x] = 255
                    stack.append(y * width + x)
                }
            }
            // Out along the ink, eight ways, within reach of the staff.
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= lowest, ny <= highest else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let n = ny * width + nx
                        if mask[n] == 0, inked(n) {
                            mask[n] = 255
                            stack.append(n)
                        }
                    }
                }
            }
        }

        // Two pixels round each, for the edge between ink and paper: one
        // left a bright rim round every note head, hollow on a dark page.
        var grown = mask
        let edge = 2
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                for ny in max(0, y - edge)...min(height - 1, y + edge) {
                    for nx in max(0, x - edge)...min(width - 1, x + edge) { grown[ny * width + nx] = 255 }
                }
            }
        }
        return grown
    }
}
