//
//  check-print-layout.swift
//  SolaPraise
//
//  Checks that a page goes on paper whole: the right paper for the place,
//  turned for a wide chart, as large as fits inside the margin, across the
//  middle and from the top — a tall photo, a wide chart and a page larger
//  than the paper alike.
//
//  WHY THIS EXISTS: a page that does not fit its sheet is cut by the
//  printer, or split over two — found only when it is printed.
//
//  Run:
//      swiftc -O -o /tmp/print-layout \
//          Sources/Chords/PrintLayout.swift Tools/check-print-layout.swift
//      /tmp/print-layout
//

import Foundation
import CoreGraphics

@main
struct CheckPrintLayout {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }
        func inside(_ r: CGRect, _ sheet: CGSize) -> Bool {
            let m = PrintLayout.margin - 0.01
            return r.minX >= m && r.minY >= m && r.maxX <= sheet.width - m && r.maxY <= sheet.height - m
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

        expect(PrintLayout.paper(region: "US") == PrintLayout.letter, "Letter in the US")
        expect(PrintLayout.paper(region: "KR") == PrintLayout.a4, "A4 in Korea")
        expect(PrintLayout.paper(region: nil) == PrintLayout.a4, "A4 when the place is not known")

        let letter = PrintLayout.letter
        // A chart page with a notice strip above it: taller than the paper's shape.
        let tall = CGSize(width: 639, height: 942)
        let sheet = PrintLayout.sheet(for: tall, paper: letter)
        expect(sheet == letter, "upright for a tall page")
        let r = PrintLayout.place(tall, on: sheet)
        expect(inside(r, sheet), "inside the margin")
        expect(close(r.minY, PrintLayout.margin), "from the top")
        expect(close(r.width / r.height, tall.width / tall.height), "its shape kept")
        expect(close(r.height, letter.height - PrintLayout.margin * 2), "as tall as fits")
        expect(close(r.midX, letter.width / 2), "across the middle")

        // A long phone screenshot: very tall, narrow.
        let long = CGSize(width: 595, height: 2400)
        let l = PrintLayout.place(long, on: PrintLayout.sheet(for: long, paper: letter))
        expect(inside(l, letter), "a long screenshot on one sheet")

        // A wide chart: the sheet is turned.
        let wide = CGSize(width: 842, height: 595)
        let wideSheet = PrintLayout.sheet(for: wide, paper: letter)
        expect(wideSheet.width > wideSheet.height, "turned for a wide chart")
        expect(inside(PrintLayout.place(wide, on: wideSheet), wideSheet), "a wide chart inside the margin")

        // A small page is made larger, not left small.
        let small = CGSize(width: 300, height: 400)
        let s = PrintLayout.place(small, on: letter)
        expect(s.width > small.width && inside(s, letter), "a small page enlarged to the paper")

        if failures == 0 {
            print("all print layout checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
