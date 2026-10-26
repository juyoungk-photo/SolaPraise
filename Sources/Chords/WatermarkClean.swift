//
//  WatermarkClean.swift
//  SolaPraise
//
//  A publisher's logo printed faintly across a chart, taken off the page
//  before 어둡게 보기 inverts it.
//
//  WHY: on the light page a grey watermark sits behind the notes and the
//  eye reads past it. Inverted, it becomes a grey slab over white notes
//  and words, and a line of lyrics printed across it cannot be read.
//
//  HOW: the way document scanners take a watermark out, with no model. A
//  page has three kinds of pixel: ink (dark), paper (white) and, between
//  them, grey. A watermark is grey and THICK — letters hundreds of pixels
//  tall — where everything else grey on a page is thin: a hymnal's grey
//  staff lines, the soft edge of a note, a word printed in a lighter ink.
//  So the grey pixels are eroded by a few pixels (every thin thing
//  vanishes), what survives is grown back a little past its rim, and
//  those pixels become paper. Ink and the pixel beside it are never
//  touched, so a note printed over the logo keeps its edge.
//
//  Core Image's document enhancer, tried first, leaves a mid-grey
//  watermark as it is: it is made for shadows and paper tint.
//
//  CoreGraphics only, so Tools/check-watermark-clean.swift runs it on a
//  Mac, on a drawn page with a logo, black text and grey staff lines.
//

import Foundation
import CoreGraphics

enum WatermarkClean {

    /// How thick a grey blob must be to count as a watermark, in pixels
    /// each side of a stroke: a staff line or a letter's stroke is thinner.
    static let radius = 4

    /// 255 where the page's grey is a watermark, 0 elsewhere — from the
    /// page's grey pixels, `width` to a row. Nil when nothing is found,
    /// so a clean page costs nothing more.
    ///
    /// Judged at a quarter of the size: a logo is hundreds of pixels
    /// across, the JPEG speckle inside it averages away (at full size it
    /// punched holes the erosion then tore open), and a radius of one
    /// there is four on the page — and the page at full size is sixteen
    /// times the work, which on a phone was the seconds between opening a
    /// page and seeing it dark.
    static func mask(gray: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let step = width >= 1000 ? 4 : 2
        guard width > step * (4 * radius + 16), height > step * (4 * radius + 16), gray.count >= width * height else { return nil }
        // Ink is dark. Otsu's split parts it from the rest on a page with
        // plenty of it; on a page with little, a big logo can pull the
        // split up to the paper — so never above a dark grey.
        let inkLimit = Int32(min(inkThreshold(gray), 110))
        // Grey is what is clearly darker than the paper: a logo may be
        // printed at a tenth of black, not a third.
        let paper = Int32(paperLevel(gray))
        let greyLimit = paper - 12

        // Ink, at full size, and the two pixels round every stroke: its
        // soft edge is grey too, and stays. Reduced, a black staff line
        // would read as grey — so no square holding ink is ever grey.
        var inkFull = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) where Int32(gray[i]) <= inkLimit { inkFull[i] = 1 }
        let nearInkFull = dilated(inkFull, width: width, height: height, by: 2)

        // The page reduced, each pixel the mean of its square.
        let sw = width / step, sh = height / step
        var small = [Int32](repeating: 255, count: sw * sh)
        var inked = [Bool](repeating: false, count: sw * sh)
        for y in 0..<sh {
            for x in 0..<sw {
                var sum: Int32 = 0
                var hasInk = false
                for dy in 0..<step { for dx in 0..<step {
                    let j = (y * step + dy) * width + x * step + dx
                    sum += Int32(gray[j])
                    if inkFull[j] != 0 { hasInk = true }
                } }
                small[y * sw + x] = sum / Int32(step * step)
                inked[y * sw + x] = hasInk
            }
        }

        // Grey: neither ink nor paper, and no ink in the square.
        var band = [UInt8](repeating: 0, count: sw * sh)
        var any = false
        for i in 0..<(sw * sh) where !inked[i] && small[i] > inkLimit && small[i] < greyLimit { band[i] = 1; any = true }
        guard any else { return nil }

        // Thick grey: what survives being eroded by the radius.
        let r = max(1, radius / step)
        let core = eroded(band, width: sw, height: sh, by: r)
        guard core.contains(1) else { return nil }
        // Grown back past its rim, within the grey, to take the soft edge
        // a scan or a JPEG leaves round the logo.
        let region = dilated(core, width: sw, height: sh, by: r + 2)
        // The logo's own grey: what is darker than it by a clear margin —
        // a hymnal's grey staff line running across it — is not the logo.
        var levels: [Int32] = []
        for i in 0..<(sw * sh) where core[i] != 0 { levels.append(small[i]) }
        levels.sort()
        let logoLevel = levels[levels.count / 2]
        let darkest = max(inkLimit + 1, logoLevel - 30)

        var found = false
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<sh {
            for x in 0..<sw {
                let i = y * sw + x
                guard region[i] != 0, small[i] >= darkest, small[i] < paper else { continue }
                // Back to full size: each pixel of the square that is grey
                // itself and not beside a stroke.
                for dy in 0..<step { for dx in 0..<step {
                    let j = (y * step + dy) * width + x * step + dx
                    if nearInkFull[j] == 0, Int32(gray[j]) >= darkest { out[j] = 255; found = true }
                } }
            }
        }
        return found ? out : nil
    }

    /// Where ink ends and grey begins: Otsu's split of the page's grey
    /// levels, which on a printed page parts the ink from the rest.
    static func inkThreshold(_ gray: [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for g in gray { hist[Int(g)] += 1 }
        let total = gray.count
        var sumAll = 0
        for (g, n) in hist.enumerated() { sumAll += g * n }
        var sumB = 0, weightB = 0, best = 0.0, split = 128
        for t in 0..<256 {
            weightB += hist[t]
            guard weightB > 0 else { continue }
            let weightF = total - weightB
            guard weightF > 0 else { break }
            sumB += t * hist[t]
            let meanB = Double(sumB) / Double(weightB), meanF = Double(sumAll - sumB) / Double(weightF)
            let between = Double(weightB) * Double(weightF) * (meanB - meanF) * (meanB - meanF)
            if between > best { best = between; split = t }
        }
        return UInt8(split)
    }

    // Square erosion and dilation, each a horizontal pass then a vertical
    // one over running sums: the page's size, whatever the radius.

    static func eroded(_ m: [UInt8], width: Int, height: Int, by r: Int) -> [UInt8] {
        windowed(m, width: width, height: height, by: r, full: true)
    }

    static func dilated(_ m: [UInt8], width: Int, height: Int, by r: Int) -> [UInt8] {
        windowed(m, width: width, height: height, by: r, full: false)
    }

    /// 1 where the (2r+1)-square window round a pixel is all ones (`full`)
    /// or holds any one.
    private static func windowed(_ m: [UInt8], width: Int, height: Int, by r: Int, full: Bool) -> [UInt8] {
        let span = 2 * r + 1
        var rows = [Int32](repeating: 0, count: width * height)
        m.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * width
                    var sum: Int32 = 0
                    for x in 0..<min(r, width) { sum += Int32(src[row + x]) }
                    for x in 0..<width {
                        if x + r < width { sum += Int32(src[row + x + r]) }
                        if x - r - 1 >= 0 { sum -= Int32(src[row + x - r - 1]) }
                        // Beyond the edge counts as outside: never full there.
                        let inside = x >= r && x + r < width
                        dst[row + x] = full ? (inside && sum == Int32(span) ? 1 : 0) : (sum > 0 ? 1 : 0)
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        rows.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for x in 0..<width {
                    var sum: Int32 = 0
                    for y in 0..<min(r, height) { sum += src[y * width + x] }
                    for y in 0..<height {
                        if y + r < height { sum += src[(y + r) * width + x] }
                        if y - r - 1 >= 0 { sum -= src[(y - r - 1) * width + x] }
                        let inside = y >= r && y + r < height
                        dst[y * width + x] = full ? (inside && sum == Int32(span) ? 1 : 0) : (sum > 0 ? 1 : 0)
                    }
                }
            }
        }
        return out
    }

    /// The page with its watermark made paper: the masked pixels the
    /// page's own paper grey — not pure white, which on a scan's off-white
    /// paper would leave the logo's shape as a faintly lighter patch, and
    /// inverted a faintly darker one — everything else as it was, in colour.
    static func cleaned(_ page: CGImage, mask: [UInt8], gray: [UInt8]) -> CGImage? {
        let width = page.width, height = page.height
        guard mask.count >= width * height, gray.count >= width * height else { return nil }
        let paper = paperLevel(gray)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(page, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The mask was made from a grey bitmap drawn the same way, so the
        // two share a row order.
        for y in 0..<height {
            let maskRow = y * width, row = y * width * 4
            for x in 0..<width where mask[maskRow + x] != 0 {
                rgba[row + x * 4] = paper; rgba[row + x * 4 + 1] = paper; rgba[row + x * 4 + 2] = paper; rgba[row + x * 4 + 3] = 255
            }
        }
        return context.makeImage()
    }

    /// The paper's grey: the commonest level among the page's light pixels.
    static func paperLevel(_ gray: [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for g in gray where g >= 200 { hist[Int(g)] += 1 }
        var best = 255, count = -1
        for g in 200..<256 where hist[g] > count { best = g; count = hist[g] }
        return UInt8(best)
    }
}
