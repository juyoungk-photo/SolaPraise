//
//  check-chart-pages.swift
//  SolaPraise
//
//  Checks that pages joined into one chart come out whole and in order:
//  a tall photo, a wide one and a two-page PDF make four pages, each the
//  shape it was, in the order picked — and that a part that is neither a
//  PDF nor an image fails the whole join rather than dropping a page.
//
//  WHY THIS EXISTS: a chart of several pages came up as several rival
//  versions. A join that put page 2 first, or lost one, would look like a
//  chart that was simply printed that way.
//
//  Run:
//      swiftc -O -o /tmp/chart-pages \
//          Sources/Chords/ChartPages.swift Tools/check-chart-pages.swift
//      /tmp/chart-pages
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct CheckChartPages {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }

        func png(width: Int, height: Int) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, context.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }

        func pdf(_ sizes: [CGSize]) -> Data {
            let out = NSMutableData()
            let context = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: nil, nil)!
            for size in sizes {
                var box = CGRect(origin: .zero, size: size)
                context.beginPage(mediaBox: &box)
                context.endPage()
            }
            context.closePDF()
            return out as Data
        }

        func sizes(_ data: Data) -> [CGSize] {
            guard let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!) else { return [] }
            return (1...max(doc.numberOfPages, 1)).compactMap { doc.page(at: $0)?.getBoxRect(.mediaBox).size }
        }
        func near(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5 }

        let tall = png(width: 400, height: 800)
        let wide = png(width: 800, height: 400)
        let twoPages = pdf([CGSize(width: 300, height: 300), CGSize(width: 200, height: 500)])

        // In the order picked.
        if let joined = ChartPages.join([tall, wide, twoPages]) {
            let got = sizes(joined)
            let want = [CGSize(width: 842, height: 1684), CGSize(width: 842, height: 421),
                        CGSize(width: 300, height: 300), CGSize(width: 200, height: 500)]
            expect(got.count == 4, "four pages, got \(got.count)")
            expect(zip(got, want).allSatisfy(near), "pages in order and shape: \(got)")
            expect(ChartPages.pageCount(joined) == 4, "page count of the joined file")
        } else {
            expect(false, "joined nothing")
        }

        // Another order is another order.
        if let joined = ChartPages.join([twoPages, wide]) {
            let got = sizes(joined)
            expect(got.count == 3 && near(got[0], CGSize(width: 300, height: 300))
                   && near(got[2], CGSize(width: 842, height: 421)), "PDF first, then the photo: \(got)")
        } else {
            expect(false, "joined nothing (PDF first)")
        }

        expect(ChartPages.pageCount(tall) == 1, "an image is one page")
        expect(ChartPages.pageCount(twoPages) == 2, "a PDF counts its pages")
        expect(ChartPages.join([tall, Data("not a chart".utf8)]) == nil, "a part that is no page fails the join")
        expect(ChartPages.join([]) == nil, "nothing joins to nothing")

        if failures == 0 {
            print("all chart page checks passed")
        } else {
            print("\(failures) chart page check(s) failed")
            exit(1)
        }
    }
}
