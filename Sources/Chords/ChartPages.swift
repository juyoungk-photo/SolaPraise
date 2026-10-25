//
//  ChartPages.swift
//  SolaPraise
//
//  A chart of two or three pages, as one file.
//
//  A song's files are versions of its chart — the stand shows one, and a
//  chip picks another. A chart photographed a page at a time came up as
//  that many versions, page 2 a rival to page 1 rather than the page after
//  it. Pages are joined here into one PDF, in the order given — a PDF of
//  several pages is what the stand already shows down a song, and what
//  every teammate's browser opens whole.
//
//  A PDF keeps its pages as they are, vector and all; an image becomes a
//  page 842 points wide (rendered at 2× on the stand: as many pixels as
//  the chord reader wants), as tall as its shape.
//
//  CoreGraphics and ImageIO only, so Tools/check-chart-pages.swift runs it
//  on a Mac.
//

import Foundation
import CoreGraphics
import ImageIO

enum ChartPages {
    /// An image's page width, in points.
    static let imageWidth: CGFloat = 842

    /// The parts as the pages of one PDF, in order. Nil if any part is not
    /// a PDF or an image: a page silently missing is worse than none.
    static func join(_ parts: [Data]) -> Data? {
        guard !parts.isEmpty else { return nil }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }

        for part in parts {
            if let pdf = pdfDocument(part) {
                for index in 1...pdf.numberOfPages {
                    guard let page = pdf.page(at: index) else { return nil }
                    let crop = page.getBoxRect(.cropBox)
                    let turned = page.rotationAngle % 180 != 0
                    var box = CGRect(x: 0, y: 0,
                                     width: turned ? crop.height : crop.width,
                                     height: turned ? crop.width : crop.height)
                    context.beginPage(mediaBox: &box)
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0,
                                                                 preserveAspectRatio: true))
                    context.drawPDFPage(page)
                    context.endPage()
                }
            } else if let image = image(part) {
                let height = imageWidth * CGFloat(image.height) / CGFloat(max(image.width, 1))
                var box = CGRect(x: 0, y: 0, width: imageWidth, height: height)
                context.beginPage(mediaBox: &box)
                context.interpolationQuality = .high
                context.draw(image, in: box)
                context.endPage()
            } else {
                return nil
            }
        }
        context.closePDF()
        return out as Data
    }

    /// How many pages a file holds: a PDF's count, an image's one.
    static func pageCount(_ data: Data) -> Int {
        pdfDocument(data)?.numberOfPages ?? (image(data) == nil ? 0 : 1)
    }

    private static func pdfDocument(_ data: Data) -> CGPDFDocument? {
        guard data.starts(with: Array("%PDF".utf8)),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        return document
    }

    /// The image upright, as its EXIF orientation says it was held.
    private static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
