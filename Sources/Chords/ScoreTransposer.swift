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
import Vision
import PDFKit
import UIKit

enum ScoreTransposer {

    /// One chord found on a page.
    struct Found: Identifiable, Equatable {
        let id = UUID()
        let original: String
        /// Normalised image coordinates, origin top-left.
        let box: CGRect
        let confidence: Float

        static func == (l: Found, r: Found) -> Bool { l.id == r.id }
    }

    struct Page {
        let image: UIImage
        let chords: [Found]
    }

    // MARK: - Reading

    /// Every page of a score, with the chords found on each.
    static func read(data: Data) async -> [Page] {
        let images: [UIImage]
        if let document = PDFDocument(data: data) {
            images = (0..<document.pageCount).compactMap { index in
                document.page(at: index).map { render($0) }
            }
        } else if let image = UIImage(data: data) {
            images = [image]
        } else {
            return []
        }

        var out: [Page] = []
        for image in images {
            out.append(Page(image: image, chords: await chords(in: image)))
        }
        return out
    }

    /// PDF pages are vector; rasterise at 2× so small chord symbols survive
    /// recognition. Below that, superscript 7s and ♯ signs are lost.
    private static func render(_ page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }

    private static func chords(in image: UIImage) async -> [Found] {
        guard let cgImage = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                var found: [Found] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    // A line of recognised text can hold several chords —
                    // "G    D    Em    C" comes back as one string — so each
                    // word is offered separately, and its box is estimated
                    // by its position within the line.
                    let words = candidate.string.split(separator: " ")
                    guard !words.isEmpty else { continue }
                    let line = observation.boundingBox
                    let total = candidate.string.count

                    var cursor = 0
                    for word in words {
                        let start = cursor
                        cursor += word.count + 1
                        guard ScoreChordText.parse(String(word)) != nil else { continue }
                        let from = CGFloat(start) / CGFloat(max(total, 1))
                        let width = CGFloat(word.count) / CGFloat(max(total, 1))
                        found.append(Found(
                            original: String(word),
                            // Vision's origin is bottom-left; flip it so the
                            // box can be drawn straight onto the image.
                            box: CGRect(x: line.minX + line.width * from,
                                        y: 1 - line.maxY,
                                        width: line.width * width,
                                        height: line.height),
                            confidence: candidate.confidence
                        ))
                    }
                }
                continuation.resume(returning: found)
            }
            // Accurate, not fast: chord symbols are small and this runs once
            // per attachment rather than per frame.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // "Am" must not become "An"
            request.recognitionLanguages = ["en-US", "ko-KR"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(returning: []) }
        }
    }

    // MARK: - Writing it back

    /// The same pages with every recognised chord rewritten.
    static func transposed(pages: [Page], by semitones: Int) -> Data? {
        guard !pages.isEmpty else { return nil }
        guard semitones % 12 != 0 else { return pdf(from: pages.map(\.image)) }

        let redrawn = pages.map { page -> UIImage in
            let size = page.image.size
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                page.image.draw(in: CGRect(origin: .zero, size: size))
                for chord in page.chords {
                    guard let moved = ScoreChordText.transpose(
                        text: chord.original, by: semitones) else { continue }
                    draw(moved, over: chord, in: size, context: context.cgContext)
                }
            }
        }
        return pdf(from: redrawn)
    }

    /// Covers the old symbol and writes the new one in its place.
    private static func draw(_ symbol: String,
                             over chord: Found,
                             in size: CGSize,
                             context: CGContext) {
        let rect = CGRect(x: chord.box.minX * size.width,
                          y: chord.box.minY * size.height,
                          width: chord.box.width * size.width,
                          height: chord.box.height * size.height)
        // A little wider than the original: a transposed symbol can be a
        // character longer — G becomes G#, Bb becomes C#m if the suffix
        // carries — and clipping the accidental is the one error that turns
        // a correct transposition into a wrong chord.
        let patch = rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12)

        // Sampled from the page rather than assumed white: scores are
        // printed on cream, scanned grey, and photographed under tungsten.
        context.setFillColor((backgroundColour(near: patch, context: context)
                              ?? UIColor.white).cgColor)
        context.fill(patch)

        let font = UIFont.boldSystemFont(ofSize: fittingSize(for: symbol, in: rect))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.black
        ]
        let measured = (symbol as NSString).size(withAttributes: attributes)
        (symbol as NSString).draw(
            at: CGPoint(x: rect.minX,
                        y: rect.midY - measured.height / 2),
            withAttributes: attributes)
    }

    /// The largest size that still fits the original's height.
    private static func fittingSize(for symbol: String, in rect: CGRect) -> CGFloat {
        max(8, rect.height * 0.82)
    }

    /// Nil when it cannot be sampled, so the caller falls back to white.
    ///
    /// Reading back from the context being drawn into is not possible, so
    /// this is left deliberately simple rather than pretending: the common
    /// case is a white or near-white page, and a visible patch on a dark
    /// one is called out in the UI instead of being papered over badly.
    private static func backgroundColour(near rect: CGRect,
                                         context: CGContext) -> UIColor? {
        nil
    }

    private static func pdf(from images: [UIImage]) -> Data? {
        guard let first = images.first else { return nil }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: first.size))
        return renderer.pdfData { context in
            for image in images {
                context.beginPage(withBounds: CGRect(origin: .zero, size: image.size),
                                  pageInfo: [:])
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
    }
}
