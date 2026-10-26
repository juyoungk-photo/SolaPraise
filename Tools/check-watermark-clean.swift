//
//  check-watermark-clean.swift
//  SolaPraise
//
//  Draws a chart page with a publisher's grey logo across it — black
//  notes, words and chords over the logo, and a hymnal's grey staff lines
//  — and checks that WatermarkClean takes the logo and nothing else.
//
//  WHY THIS EXISTS: the cleaner is a rule about thickness and grey. Too
//  eager, it eats a hymnal's grey staff lines or a word printed light,
//  and the page loses its music with nothing to say so; too timid, the
//  logo stays and a dark page is a grey slab over the lyrics. Both are
//  measured here, pixel by pixel.
//
//  Run:
//      swiftc -O -o /tmp/watermarkclean \
//          Sources/Chords/WatermarkClean.swift Tools/check-watermark-clean.swift
//      /tmp/watermarkclean
//

import Foundation
import AppKit

@main
struct CheckWatermarkClean {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
        }
        if !ok { failures += 1 }
    }

    static let width = 1240, height = 900

    /// Grey levels, top-down, of a page drawn by `draw`.
    static func page(_ draw: (CGContext) -> Void) -> [UInt8] {
        var gray = [UInt8](repeating: 255, count: width * height)
        let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return gray
    }

    static func text(_ s: String, at p: CGPoint, size: CGFloat, gray g: CGFloat, in ctx: CGContext, bold: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: NSColor(white: g, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func main() {
        // The logo: huge grey letters across the middle of the page.
        let logoGray: CGFloat = 0.72
        let plain = page { ctx in
            // Black staff lines and notes above the logo's rows, grey
            // (hymnal) staff lines below, black words across the logo.
            for i in 0..<5 { ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 80, y: 700 + i * 12, width: 1080, height: 2)) }
            for i in 0..<5 { ctx.setFillColor(gray: 0.55, alpha: 1); ctx.fill(CGRect(x: 80, y: 200 + i * 12, width: 1080, height: 2)) }
            for x in stride(from: 150, to: 1100, by: 90) {
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fillEllipse(in: CGRect(x: x, y: 712, width: 14, height: 10))
                ctx.fill(CGRect(x: x + 12, y: 716, width: 2, height: 40))
            }
            text("거룩 하신 전능의 주 찬양 받기 합당한 주", at: CGPoint(x: 150, y: 640), size: 28, gray: 0, in: ctx)
            text("G        C        Am7        D", at: CGPoint(x: 150, y: 770), size: 24, gray: 0, in: ctx)
            text("나의 평생 주님 만을 사랑 하며", at: CGPoint(x: 150, y: 150), size: 28, gray: 0, in: ctx)
        }
        let marked = page { ctx in
            text("ISAIAH", at: CGPoint(x: 250, y: 420), size: 230, gray: logoGray, in: ctx, bold: true)
            text("6tyOne", at: CGPoint(x: 300, y: 260), size: 170, gray: logoGray, in: ctx, bold: true)
            for i in 0..<5 { ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 80, y: 700 + i * 12, width: 1080, height: 2)) }
            for i in 0..<5 { ctx.setFillColor(gray: 0.55, alpha: 1); ctx.fill(CGRect(x: 80, y: 200 + i * 12, width: 1080, height: 2)) }
            for x in stride(from: 150, to: 1100, by: 90) {
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fillEllipse(in: CGRect(x: x, y: 712, width: 14, height: 10))
                ctx.fill(CGRect(x: x + 12, y: 716, width: 2, height: 40))
            }
            text("거룩 하신 전능의 주 찬양 받기 합당한 주", at: CGPoint(x: 150, y: 640), size: 28, gray: 0, in: ctx)
            text("G        C        Am7        D", at: CGPoint(x: 150, y: 770), size: 24, gray: 0, in: ctx)
            text("나의 평생 주님 만을 사랑 하며", at: CGPoint(x: 150, y: 150), size: 28, gray: 0, in: ctx)
        }

        let logoOnly = page { ctx in
            text("ISAIAH", at: CGPoint(x: 250, y: 420), size: 230, gray: logoGray, in: ctx, bold: true)
            text("6tyOne", at: CGPoint(x: 300, y: 260), size: 170, gray: logoGray, in: ctx, bold: true)
        }

        let t0 = Date()
        let mask = WatermarkClean.mask(gray: marked, width: width, height: height)
        let seconds = Date().timeIntervalSince(t0)
        check("a page with a logo yields a mask", mask != nil)
        guard let mask else { exit(1) }
        print(String(format: "     (%.2fs for a %dx%d page)", seconds, width, height))

        // The logo's own pixels: nearly all taken.
        var logo = 0, taken = 0
        for i in 0..<(width * height) where logoOnly[i] < 235 && marked[i] > 140 {
            logo += 1
            if mask[i] != 0 { taken += 1 }
        }
        check("the logo goes", Double(taken) >= Double(logo) * 0.95, "\(taken) of \(logo) logo pixels")

        // Ink — black text, notes, black staff lines — untouched.
        var ink = 0, inkTaken = 0
        for i in 0..<(width * height) where plain[i] < 100 {
            ink += 1
            if mask[i] != 0 { inkTaken += 1 }
        }
        check("black ink stays", inkTaken == 0, "\(inkTaken) of \(ink) ink pixels taken")

        // A hymnal's grey staff lines — grey like the logo, but thin — stay.
        // Their rows: the plain page's rows that are mostly a mid grey.
        var lines = 0, linesTaken = 0
        for y in 0..<height {
            var greyRun = 0
            for x in 80..<1160 where plain[y * width + x] > 100 && plain[y * width + x] < 200 { greyRun += 1 }
            guard greyRun > 800 else { continue }
            for x in 80..<1160 where plain[y * width + x] < 200 {
                lines += 1
                if mask[y * width + x] != 0 { linesTaken += 1 }
            }
        }
        check("grey staff lines stay", lines > 1000 && linesTaken == 0, "\(linesTaken) of \(lines) grey line pixels taken")

        // A clean page needs nothing.
        check("a page without a logo yields no mask", WatermarkClean.mask(gray: plain, width: width, height: height) == nil)

        if failures == 0 { print("\nall watermark clean checks passed") } else { print("\n\(failures) failure(s)"); exit(1) }
    }
}
