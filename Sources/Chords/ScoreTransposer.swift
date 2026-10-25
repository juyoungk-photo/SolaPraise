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
        /// What was found, as the reader may since have moved, corrected,
        /// removed or added to it.
        var chords: [ScoreChord]
        /// The page's size in points as it came in — a PDF page's own size,
        /// an image fitted to A4 width — so the export is the same shape of
        /// page, not one doubled by the rasterising scale.
        let pointSize: CGSize
        /// Marks drawn by hand (ScoreInk), the page's size, laid over it in
        /// what is exported — as drawn, pressure and texture and all.
        var ink: UIImage? = nil

        init(image: UIImage, found: [Found], pointSize: CGSize) {
            self.image = image
            self.chords = found.map { ScoreChord(original: $0.original, box: $0.box) }
            self.pointSize = pointSize
        }

        init(image: UIImage, chords: [ScoreChord], pointSize: CGSize) {
            self.image = image
            self.chords = chords
            self.pointSize = pointSize
        }

        /// The height chords on this page are set at, as a share of the
        /// page — the median of what was found.
        ///
        /// Each box's own height varies with the letters in it and with
        /// which pass found it, and sizing each replacement from its own
        /// box made a lone "A" half the size of the "Asus4" beside it. A
        /// chart sets its chords in one size, so the replacement does too.
        var chordHeight: CGFloat {
            let heights = chords.filter { !$0.userAdded }.map(\.box.height).sorted()
            guard !heights.isEmpty else { return 0.012 }
            return heights[heights.count / 2]
        }
    }

    enum Source { case pdf, image }

    // MARK: - Reading

    /// Every page of a score, with the chords found on each, or nil when
    /// the bytes are neither a PDF nor an image — which is what a Drive
    /// link that is not shared by link returns: an HTML sign-in page.
    /// `recognise: false` skips the chord reading — for a chart whose
    /// chords the reader has already corrected and saved.
    /// `only`: the page indices to read, for one song's pages of a 콘티 file.
    static func read(data: Data, recognise: Bool = true, only: [Int]? = nil) async -> (pages: [Page], source: Source)? {
        // Off the main thread: recognition is several seconds a page.
        await Task.detached(priority: .userInitiated) {
            if let document = PDFDocument(data: data), document.pageCount > 0 {
                let indices = only?.filter { $0 < document.pageCount } ?? Array(0..<document.pageCount)
                let pages = indices.compactMap { index -> Page? in
                    guard let page = document.page(at: index) else { return nil }
                    let image = render(page)
                    return Page(image: image,
                                found: recognise ? image.cgImage.map(ScoreRecognition.chords(in:)) ?? [] : [],
                                pointSize: page.bounds(for: .cropBox).size)
                }
                return (pages, .pdf)
            }
            guard var image = UIImage(data: data)?.normalisedOrientation() else { return nil }
            // A small image — a chart saved off a web page or a messenger,
            // 600 px across — lost chords that the same chart at 1600 px
            // gave whole: 「B7」 read as 「B」, an 「E7」 gone. Enlarged first,
            // to read and to show alike.
            let pixelWidth = image.size.width * image.scale
            if pixelWidth < 1400 {
                let factor = 1600 / max(pixelWidth, 1)
                let size = CGSize(width: 1600, height: image.size.height * image.scale * factor)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    context.cgContext.interpolationQuality = .high
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            let width: CGFloat = 595
            let size = CGSize(width: width,
                              height: width * image.size.height / max(image.size.width, 1))
            return ([Page(image: image,
                          found: recognise ? image.cgImage.map(ScoreRecognition.chords(in:)) ?? [] : [],
                          pointSize: size)], .image)
        }.value
    }

    /// PDF pages are vector; rasterise at 2× so small chord symbols survive
    /// recognition. Below that, superscript 7s and ♯ signs are lost.
    /// The page as a viewer shows it — its crop box. The media box can be
    /// the whole sheet, frames and crop marks round the page included, and a
    /// 콘티 made from it had a border on those pages and not on others.
    private static func render(_ page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .cropBox)
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
            page.draw(with: .cropBox, to: context.cgContext)
        }
    }

    // MARK: - Writing it back

    /// The same pages with every chord rewritten, as a PDF — laid out by
    /// ScoreLayout exactly as the stand showed them.
    /// - caption: a line for the top-left corner of every page — a 콘티's
    ///   「2026/10/18 주일2부 - 1. 곡」 (ContiCaption). It goes on a strip
    ///   added above the page rather than over it: a chart's own corner
    ///   holds its title, its key or a chord, and a line over them hid both.
    /// - notice: more for the strip, under the caption — a 헌금송's prayer
    ///   and call. Its first line set apart, the rest wrapped to the page;
    ///   large enough to be read out from a stand (it was a tenth of an
    ///   inch high, and could not be).
    ///
    /// Every page has a margin all round, white: a chart printed to its
    /// edges ran into the printer's own edge, and on a screen sat against
    /// the frame.
    static func transposed(pages: [Page], by semitones: Int, useFlats: Bool? = nil,
                           scale: CGFloat = 1, caption: String? = nil, notice: String? = nil) -> Data? {
        guard !pages.isEmpty else { return nil }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pages[0].pointSize))
        return renderer.pdfData { context in
            for (index, page) in pages.enumerated() {
                let size = page.pointSize
                let fontSize = max(9, size.width * 0.017)
                // Close to the corner: the chart's own margin is below it.
                let margin = max(6, size.width * 0.012)
                // Round the whole page.
                let pad = max(8, size.width * 0.022)
                // The notice on the song's first page only: read once, before it.
                let block = index == 0 ? notice.map { noticeText($0, fontSize: max(13, size.width * 0.028)) } : nil
                let blockHeight = block.map {
                    ceil($0.boundingRect(with: CGSize(width: size.width - margin * 2, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], context: nil).height) + fontSize * 0.8
                } ?? 0
                let captionHeight = caption == nil ? 0 : (fontSize * 2).rounded()
                let strip = captionHeight + blockHeight
                let full = CGSize(width: size.width + pad * 2, height: size.height + strip + pad * 2)
                context.beginPage(withBounds: CGRect(origin: .zero, size: full), pageInfo: [:])
                let cg = context.cgContext
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: full))
                cg.saveGState()
                cg.translateBy(x: pad, y: pad)
                if let caption {
                    (caption as NSString).draw(
                        at: CGPoint(x: margin, y: (captionHeight - fontSize * 1.2) / 2),
                        withAttributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                                         .foregroundColor: UIColor.darkGray])
                }
                if let block {
                    block.draw(with: CGRect(x: margin, y: captionHeight, width: size.width - margin * 2,
                                            height: blockHeight),
                               options: [.usesLineFragmentOrigin], context: nil)
                }
                cg.saveGState()
                cg.translateBy(x: 0, y: strip)
                let bounds = CGRect(origin: .zero, size: size)
                page.image.draw(in: bounds)
                let labels = ScoreLayout.labels(
                    chords: page.chords, chordHeight: page.chordHeight, shift: semitones,
                    useFlats: useFlats, scale: scale, in: bounds.size)
                ScoreLayout.draw(labels, in: cg)
                page.ink?.draw(in: bounds)
                cg.restoreGState()
                cg.restoreGState()
            }
        }
    }

    /// A notice as drawn: its first line bold, the rest as a paragraph.
    private static func noticeText(_ notice: String, fontSize: CGFloat) -> NSAttributedString {
        let lines = notice.components(separatedBy: "\n")
        let out = NSMutableAttributedString(string: (lines.first ?? "") + (lines.count > 1 ? "\n" : ""),
                                            attributes: [.font: UIFont.systemFont(ofSize: fontSize * 1.05, weight: .bold),
                                                         .foregroundColor: UIColor.black])
        if lines.count > 1 {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.25
            style.paragraphSpacingBefore = fontSize * 0.3
            out.append(NSAttributedString(string: lines.dropFirst().joined(separator: "\n"),
                                          attributes: [.font: UIFont.systemFont(ofSize: fontSize * 0.95),
                                                       .foregroundColor: UIColor.black,
                                                       .paragraphStyle: style]))
        }
        return out
    }

    /// Each page as an image, chords drawn as on the stand — for Photos.
    /// At the page image's own resolution, so nothing is lost to saving.
    static func images(pages: [Page], by semitones: Int, useFlats: Bool? = nil,
                       scale: CGFloat = 1) -> [UIImage] {
        pages.map { page in
            let size = page.pointSize
            let format = UIGraphicsImageRendererFormat()
            format.scale = max(1, page.image.size.width * page.image.scale / max(1, size.width))
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                page.image.draw(in: CGRect(origin: .zero, size: size))
                let labels = ScoreLayout.labels(
                    chords: page.chords, chordHeight: page.chordHeight, shift: semitones,
                    useFlats: useFlats, scale: scale, in: size)
                ScoreLayout.draw(labels, in: context.cgContext)
                page.ink?.draw(in: CGRect(origin: .zero, size: size))
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
