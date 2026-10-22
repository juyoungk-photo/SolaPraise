//
//  check-xfdf.swift
//  SolaPraise
//
//  Checks a chart's corrections as XFDF: written and read back the same,
//  each chord at its place in PDF points on its page of the file, only
//  the changed ones shown to other readers, text that needs escaping
//  kept whole, and changes written as <add>, <modify>, <delete>.
//
//  WHY THIS EXISTS: a chord read back at the wrong place, or a
//  correction that a PDF app shows over every printed chord, is a chart
//  nobody can read — and it would only be seen on someone else's phone.
//
//  Run:
//      swiftc -O -o /tmp/xfdf \
//          Sources/Team/XFDF.swift Tools/check-xfdf.swift
//      /tmp/xfdf
//

import Foundation
import CoreGraphics

@main
struct CheckXFDF {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        typealias Mark = XFDF.Mark
        let printed = Mark(name: "A1", part: 0, box: CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.02), text: "G")
        let fixed = Mark(name: "B2", part: 0, box: CGRect(x: 0.5, y: 0.2, width: 0.05, height: 0.02),
                         text: "C/E", corrected: true)
        let added = Mark(name: "C3x", part: 1, box: CGRect(x: 0.25, y: 0.5, width: 0.04, height: 0.02),
                         text: "D<sus>&\"4\"", userAdded: true)
        let moved = Mark(name: "D4", part: 1, box: CGRect(x: 0.7, y: 0.5, width: 0.04, height: 0.02),
                         offset: CGSize(width: 0.01, height: -0.005), text: "Em")
        let document = XFDF.Document(pages: [[printed, fixed], [added, moved], []],
                                     lyrics: [.init(system: 2, bar: 1, cell: 3, verse: 0, from: "주께", to: "주의")])
        // A song of a 콘티 file: its pages are the file's 4th to 6th.
        let xml = XFDF.encode(document, pdfPages: [3, 4, 5], sizes: [CGSize(width: 600, height: 800)])

        expect(XFDF.decode(xml), document, "read back as written, empty page and all")
        expect(xml.contains("xmlns=\"http://ns.adobe.com/xfdf/\""), true, "the standard's namespace")
        expect(xml.contains("<freetext page=\"3\""), true, "on its page of the file")
        expect(xml.components(separatedBy: "flags=\"hidden\"").count - 1, 2, "the printed chord and the lyric fix hidden; the changes shown")
        // 0.5..0.55 of 600 wide; 0.2..0.22 down of 800 high, from the bottom.
        expect(xml.contains("rect=\"300.00,624.00,330.00,640.00\""), true, "in PDF points, origin bottom-left")
        expect(XFDF.decode("<html></html>") == nil, true, "not XFDF")

        let command = XFDF.command(add: [added], modify: [fixed], delete: [printed], pdfPages: [3, 4, 5], sizes: [])
        guard let read = XFDF.decodeCommand(command) else { print("FAIL: command unread"); exit(1) }
        expect(read.add, [added], "added")
        expect(read.modify, [fixed], "changed")
        expect(read.delete.map(\.name), ["A1"], "taken off, by name")
        expect(read.delete.first?.box, printed.box, "and by place")
        expect(command.contains("<delete><id page=\"3\""), true, "the standard's delete")

        // A 콘티 file's page map, as XFDF form fields.
        let map = XFDF.Document(pages: [], fields: ["page.0": "빛의 노래", "page.2": "새벽 & 노래"])
        expect(XFDF.decode(XFDF.encode(map, pdfPages: [], sizes: [])), map, "fields read back as written")

        // Strokes drawn by hand, one person's layer.
        let stroke = XFDF.Ink(name: "s0", part: 1, points: [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.2, y: 0.5)],
                              width: 0.005, color: "#FF3B30", opacity: 1)
        let mark = XFDF.Ink(name: "s1", part: 0, points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.6, y: 0.3)],
                            width: 0.02, color: "#FFCC00", opacity: 0.35, marker: true)
        let layer = XFDF.Document(pages: [[], []], inks: [stroke, mark], author: "가람")
        let inkXML = XFDF.encode(layer, pdfPages: [0, 1], sizes: [CGSize(width: 600, height: 800), CGSize(width: 600, height: 800)])
        guard let back = XFDF.decode(inkXML) else { print("FAIL: ink unread"); exit(1) }
        expect(back.author, "가람", "whose strokes, as the standard's title")
        expect(back.inks.count, 2, "both strokes")
        expect(back.inks[0].points.map { (Double($0.x) * 1000).rounded() }, [100, 200], "points back across the page")
        expect(back.inks[0].points.map { (Double($0.y) * 1000).rounded() }, [250, 500], "and down it")
        expect((Double(back.inks[0].width) * 1000).rounded(), 5, "width as a share of the page")
        expect(back.inks[1].marker && back.inks[1].opacity == 0.35, true, "a highlighter, see-through")
        expect(inkXML.contains("<ink page=\"1\""), true, "the standard's ink, on its page")
        expect(inkXML.contains("<gesture>60.00,600.00;120.00,400.00</gesture>"), true, "in PDF points, origin bottom-left")

        // A hand's stroke: a point every few pixels, kept to its shape.
        let wobble = (0...200).map { i in CGPoint(x: Double(i) / 400, y: 0.5 + (i % 2 == 0 ? 0.0001 : -0.0001)) }
        expect(XFDF.simplify(wobble).count, 2, "a straight line, two points")
        let corner = (0...100).map { CGPoint(x: Double($0) / 200, y: 0.2) } + (1...100).map { CGPoint(x: 0.5, y: 0.2 + Double($0) / 200) }
        expect(XFDF.simplify(corner).count, 3, "an L, three points")

        if failures == 0 {
            print("all xfdf checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
