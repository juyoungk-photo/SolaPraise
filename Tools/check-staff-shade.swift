//
//  check-staff-shade.swift
//  SolaPraise
//
//  Checks what 오선·음표 밝기 shades on a drawn page: the staff, a note
//  hung below it on its stem and a stem rising above it — and not the
//  lyric line set close under it (a hymn's spacing), nor a chord printed
//  level with the top of that stem, nor a lyric set tighter still under a
//  bare staff. A staff found with four lines of five still has its fifth
//  shaded, joined by the bar line.
//
//  WHY THIS EXISTS: the shade greyed the top half of a hymn's first lyric
//  line, then the foot of chords beside a tall stem. Both look like a
//  rendering glitch, not a rule that missed.
//
//  Run:
//      swiftc -O -o /tmp/staff-shade \
//          Sources/Chords/StaffShade.swift Tools/check-staff-shade.swift
//      /tmp/staff-shade
//

import Foundation
import CoreGraphics

@main
struct CheckStaffShade {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }

        let width = 1200, height = 800
        var gray = [UInt8](repeating: 255, count: width * height)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            for y in y0..<y1 { for x in x0..<x1 { gray[y * width + x] = 0 } }
        }

        // Staff 1: lines at 200…240, spacing 10, a bar line through them.
        for y in stride(from: 200, through: 240, by: 10) { fill(20, y, 1180, y + 2) }
        fill(600, 200, 602, 242)
        // A note below it (to 256) on a stem rising to 180.
        fill(300, 248, 312, 256); fill(310, 180, 312, 256)
        // A chord level with the stem's top, beside it: 172…186.
        fill(400, 172, 460, 186)
        // The lyric line under it, past a gap: 262…280.
        fill(100, 262, 1100, 280)

        // Staff 2: lines at 500…540, nothing below; a lyric at 545…560.
        for y in stride(from: 500, through: 540, by: 10) { fill(20, y, 1180, y + 2) }
        fill(100, 545, 1100, 560)

        func norm(_ top: Int, _ bottom: Int) -> CGRect {
            CGRect(x: 0, y: CGFloat(top) / CGFloat(height), width: 1, height: CGFloat(bottom - top) / CGFloat(height))
        }

        let mask = StaffShade.mask(gray: gray, width: width, height: height,
                                   staves: [norm(200, 242), norm(500, 542)])
        func shaded(_ x: Int, _ y: Int) -> Bool { mask[y * width + x] != 0 }
        expect(shaded(700, 220), "the staff's lines")
        expect(shaded(305, 252), "the note below the staff, on its stem")
        expect(shaded(311, 182), "the stem above the staff")
        expect(!shaded(430, 180), "the chord level with the stem's top")
        expect(!shaded(500, 270), "the lyric line under the staff")
        expect(!shaded(500, 263), "the lyric's top edge")
        expect(!shaded(500, 550), "a tight lyric under a bare staff")
        expect(shaded(700, 520), "the second staff's lines")

        // Four lines found of five: the fifth, joined by the bar line.
        let four = StaffShade.mask(gray: gray, width: width, height: height, staves: [norm(200, 232)])
        expect(four[241 * width + 700] != 0, "the fifth line the finder missed")
        expect(four[270 * width + 500] == 0, "and still not the lyric")

        expect(!StaffShade.mask(gray: gray, width: width, height: height, staves: []).contains(255),
               "no staff, nothing shaded")

        if failures == 0 {
            print("all staff shade checks passed")
        } else {
            print("\(failures) staff shade check(s) failed")
            exit(1)
        }
    }
}
