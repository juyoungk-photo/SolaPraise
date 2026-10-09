//
//  ServicePDF.swift
//  SolaPraise
//
//  One PDF for a Sunday: the 순서 on the front, then every 악보 behind it in
//  the order they are played.
//
//  WHY: on a music stand you want one document, not eleven. The team's
//  attachments arrive as whatever people had — a photo of a chart, a PDF
//  from the publisher, a screenshot — and the job of this file is to make
//  them into something you can swipe through from the first song to the
//  last without leaving the page.
//
//  PDFKit does the merging, so a multi-page PDF keeps all its pages and an
//  image becomes a page scaled to fit rather than cropped. Everything is
//  rendered locally; the only thing that leaves the device is the finished
//  document, uploaded to the same place the attachments came from.
//

import Foundation
import PDFKit
import UIKit

enum ServicePDF {

    /// A4 at 72dpi, which is what UIGraphicsPDFRenderer and most publishers
    /// assume. Matching it means a downloaded chart is not rescaled twice.
    static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 48

    struct Source {
        let name: String
        let song: String
        let data: Data
    }

    /// Builds the combined document.
    ///
    /// Returns nil only when there is nothing to put in it — the cover page
    /// alone is not worth a download.
    static func build(service: TeamService,
                      plan: [PlanItem],
                      note: ChurchNote?,
                      sources: [Source]) -> Data? {
        guard !sources.isEmpty else { return nil }

        let document = PDFDocument()
        var pageIndex = 0

        if let cover = coverPage(service: service, plan: plan, note: note) {
            document.insert(cover, at: pageIndex)
            pageIndex += 1
        }

        for source in sources {
            // A PDF keeps every page; an image becomes one.
            if let incoming = PDFDocument(data: source.data) {
                for page in 0..<incoming.pageCount {
                    guard let copied = incoming.page(at: page)?.copy() as? PDFPage else { continue }
                    document.insert(copied, at: pageIndex)
                    pageIndex += 1
                }
                continue
            }
            if let image = UIImage(data: source.data),
               let page = imagePage(image, caption: source.song.isEmpty ? source.name : source.song) {
                document.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }

        guard pageIndex > 0 else { return nil }
        return document.dataRepresentation()
    }

    // MARK: - Cover

    /// The order of service, so the document opens on what the team is
    /// actually doing rather than on page one of someone's chord chart.
    private static func coverPage(service: TeamService,
                                  plan: [PlanItem],
                                  note: ChurchNote?) -> PDFPage? {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { context in
            context.beginPage()
            var y = margin

            let date = service.date.formatted(
                .dateTime.year().month(.wide).day().weekday(.wide))
            y = draw(service.title, at: y, font: .boldSystemFont(ofSize: 24))
            y = draw(date, at: y + 2, font: .systemFont(ofSize: 13),
                     colour: .secondaryLabel)
            if let time = service.time {
                y = draw(time + (service.location.map { " · \($0)" } ?? ""),
                         at: y, font: .systemFont(ofSize: 13), colour: .secondaryLabel)
            }
            y += 10

            if let sermon = note?.sermonTitle {
                y = draw("설교  \(sermon)", at: y, font: .systemFont(ofSize: 13))
            }
            if let song = note?.dedicationSong {
                y = draw("헌신찬양  \(song)", at: y, font: .systemFont(ofSize: 13))
            }
            y += 14

            y = draw("순서", at: y, font: .boldSystemFont(ofSize: 15))
            y += 4
            for item in plan {
                let key = item.key.map { "  (\($0))" } ?? ""
                let who = item.person.map { "  · \($0)" } ?? ""
                y = draw("\(item.order).  \(item.title)\(key)\(who)",
                         at: y, font: .systemFont(ofSize: 12))
                if y > pageSize.height - margin { break }
            }
        }
        return PDFDocument(data: data)?.page(at: 0)
    }

    @discardableResult
    private static func draw(_ text: String,
                             at y: CGFloat,
                             font: UIFont,
                             colour: UIColor = .label) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour
        ]
        let width = pageSize.width - margin * 2
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        (text as NSString).draw(
            with: CGRect(x: margin, y: y, width: width, height: bounds.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        return y + bounds.height + 6
    }

    // MARK: - Images

    /// An image on its own page, scaled to fit and never cropped.
    ///
    /// A photo of a chart is usually portrait and a screenshot usually
    /// landscape, and cropping either to fill the page would cut off the
    /// first or last bar — which is the one thing a chart cannot survive.
    private static func imagePage(_ image: UIImage, caption: String) -> PDFPage? {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { context in
            context.beginPage()

            var top = margin / 2
            if !caption.isEmpty {
                top = draw(caption, at: margin / 2, font: .boldSystemFont(ofSize: 13))
            }

            let available = CGRect(
                x: margin / 2, y: top,
                width: pageSize.width - margin,
                height: pageSize.height - top - margin / 2)
            let scale = min(available.width / image.size.width,
                            available.height / image.size.height)
            let size = CGSize(width: image.size.width * scale,
                              height: image.size.height * scale)
            image.draw(in: CGRect(
                x: available.midX - size.width / 2,
                y: available.minY,
                width: size.width, height: size.height))
        }
        return PDFDocument(data: data)?.page(at: 0)
    }
}
