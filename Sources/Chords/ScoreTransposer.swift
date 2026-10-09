//
//  ScoreTransposer.swift
//  SolaPraise
//
//  Reading the chords off a score and giving the page back in another key.
//
//  Vision does the text recognition, entirely on device — no upload, no
//  key, no network. Each recognised word is offered to ScoreChordText, and
//  the ones that are chords are painted over and rewritten a few semitones
//  along. Everything else on the page is untouched, which is what makes the
//  result the SAME chart rather than a new one: the staff, the lyrics, the
//  section markings and the publisher's layout all survive because they are
//  never redrawn.
//
//  WHY PAINT OVER RATHER THAN REBUILD: a score is a designed page. Any
//  attempt to re-typeset it loses the thing that makes it usable — where
//  the chord sits relative to the syllable it falls on. Covering one word
//  and writing another in the same place keeps that alignment exactly.
//
//  The honest limits, stated here because the UI has to repeat them:
//  handwriting will not be read, a chord printed over a dark or textured
//  background will leave a visible patch, and an English chart will offer
//  up "A" and "Am" from its lyrics. The app cannot tell those from chords
//  and does not pretend to — it shows what it found and lets a person look
//  before trusting it.
//

import Foundation
import PDFKit
import UIKit

enum ScoreTransposer {

    typealias Found = ScoreRecognition.Found

    struct Page {
        let image: UIImage
        let chords: [Found]
        /// The page's size in points as it came in — a PDF page's own size,
        /// an image fitted to A4 width — so the export is the same shape of
        /// page, not one doubled by the rasterising scale.
        let pointSize: CGSize

        /// The height chords on this page are set at, as a share of the
        /// page — the median of what was found.
        ///
        /// Each box's own height varies with the letters in it and with
        /// which pass found it, and sizing each replacement from its own
        /// box made a lone "A" half the size of the "Asus4" beside it. A
        /// chart sets its chords in one size, so the replacement does too.
        var chordHeight: CGFloat {
            let heights = chords.map(\.box.height).sorted()
            guard !heights.isEmpty else { return 0 }
            return heights[heights.count / 2]
        }
    }

    enum Source { case pdf, image }

    // MARK: - Reading

    /// Every page of a score, with the chords found on each, or nil when
    /// the bytes are neither a PDF nor an image — which is what a Drive
    /// link that is not shared by link returns: an HTML sign-in page.
    static func read(data: Data) async -> (pages: [Page], source: Source)? {
        // Off the main thread: recognition is several seconds a page.
        await Task.detached(priority: .userInitiated) {
            if let document = PDFDocument(data: data), document.pageCount > 0 {
                let pages = (0..<document.pageCount).compactMap { index -> Page? in
                    guard let page = document.page(at: index) else { return nil }
                    let image = render(page)
                    return Page(image: image,
                                chords: image.cgImage.map(ScoreRecognition.chords(in:)) ?? [],
                                pointSize: page.bounds(for: .mediaBox).size)
                }
                return (pages, .pdf)
            }
            guard let image = UIImage(data: data)?.normalisedOrientation() else { return nil }
            let width: CGFloat = 595
            let size = CGSize(width: width,
                              height: width * image.size.height / max(image.size.width, 1))
            return ([Page(image: image,
                          chords: image.cgImage.map(ScoreRecognition.chords(in:)) ?? [],
                          pointSize: size)], .image)
        }.value
    }

    /// PDF pages are vector; rasterise at 2× so small chord symbols survive
    /// recognition. Below that, superscript 7s and ♯ signs are lost.
    private static func render(_ page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }

    // MARK: - Writing it back

    /// The same pages with every recognised chord rewritten, as a PDF.
    static func transposed(pages: [Page], by semitones: Int, useFlats: Bool? = nil) -> Data? {
        guard !pages.isEmpty else { return nil }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pages[0].pointSize))
        return renderer.pdfData { context in
            for page in pages {
                let bounds = CGRect(origin: .zero, size: page.pointSize)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                page.image.draw(in: bounds)
                guard semitones % 12 != 0 else { continue }
                for chord in page.chords {
                    guard let moved = symbol(chord.original, by: semitones,
                                             useFlats: useFlats) else { continue }
                    draw(moved, over: chord.box, textHeight: page.chordHeight,
                         in: bounds.size, context: context.cgContext)
                }
            }
        }
    }

    /// The transposed spelling, honouring a forced ♭/♯ choice when given.
    static func symbol(_ original: String, by semitones: Int, useFlats: Bool?) -> String? {
        guard let parsed = ScoreChordText.parse(original) else { return nil }
        let styled = useFlats.map {
            ScoreChordText.Parsed(root: parsed.root, suffix: parsed.suffix,
                                  bass: parsed.bass, usesFlats: $0)
        } ?? parsed
        return ScoreChordText.transpose(styled, by: semitones)
    }

    /// Covers the old symbol and writes the new one in its place.
    ///
    /// Shared with the on-screen preview's geometry: the patch is the found
    /// box widened a little, and the text is sized from the box height, so
    /// what the reader approved on screen is what the PDF contains.
    static func patchRect(for box: CGRect, textHeight: CGFloat, in size: CGSize) -> CGRect {
        // At least the page's chord height, centred on the found box: a box
        // read short would otherwise squeeze the new symbol to fit it.
        let height = max(box.height, textHeight) * size.height
        let rect = CGRect(x: box.minX * size.width,
                          y: box.midY * size.height - height / 2,
                          width: box.width * size.width, height: height)
        // Wider than the original: a transposed symbol can be a character
        // longer — G becomes G#, C becomes Db — and clipping the
        // accidental is the one error that turns a correct transposition
        // into a wrong chord. Mostly rightward, where the extra goes.
        return CGRect(x: rect.minX - rect.height * 0.15,
                      y: rect.minY - rect.height * 0.15,
                      width: rect.width + rect.height * 0.9,
                      height: rect.height * 1.3)
    }

    /// Point size for a symbol drawn into a box of this height.
    ///
    /// Measured, not assumed: on a page set in 15pt bold, Vision's boxes
    /// came back about 14.4pt tall — nearly the full font size, not the
    /// capital height. Dividing by the capital-height ratio (0.72) printed
    /// every replacement a third larger than the chord it replaced.
    static func fontSize(forBoxHeight height: CGFloat) -> CGFloat {
        max(6, height / 0.96)
    }

    private static func draw(_ symbol: String, over box: CGRect, textHeight: CGFloat,
                             in size: CGSize, context: CGContext) {
        let patch = patchRect(for: box, textHeight: textHeight, in: size)
        let original = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                              width: box.width * size.width, height: box.height * size.height)
        // White, not sampled: the common page is white or near it, and a
        // patch on a dark or photographed page is called out on screen.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(patch)

        var font = UIFont.boldSystemFont(ofSize: fontSize(forBoxHeight: textHeight * size.height))
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        var measured = (symbol as NSString).size(withAttributes: attributes)
        // Shrink a long result to the patch rather than over a lyric.
        if measured.width > patch.width {
            font = font.withSize(font.pointSize * patch.width / measured.width)
            attributes[.font] = font
            measured = (symbol as NSString).size(withAttributes: attributes)
        }
        (symbol as NSString).draw(
            at: CGPoint(x: original.minX, y: original.midY - measured.height / 2),
            withAttributes: attributes)
    }
}

private extension UIImage {
    /// Photos arrive rotated by EXIF rather than by pixels; recognition and
    /// drawing both need the pixels upright.
    func normalisedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: pixels))
        }
    }
}
