//
//  XFDF.swift
//  SolaPraise
//
//  A chart's corrections as XFDF — the standard XML form of a PDF's
//  annotations (ISO 19444-1) — rather than a format of this app's own.
//
//  WHY A STANDARD: the corrections are read outside this app too — by a
//  PDF app on an Android phone, by a web page, by whatever comes next.
//  XFDF is what Adobe, Xodo and most PDF tools import and export. Each
//  chord is a FreeText annotation at its place on its page, its text the
//  chord as printed in the chart's key.
//
//  What a standard reader shows: only the chords someone changed, added
//  or moved. The rest of this app's reading — every printed chord, kept
//  so the team's devices work from one reading — is there as annotations
//  flagged `hidden`. What only this app needs (where a chord was found
//  before it was dragged, whether it was added by hand, the lyric fixes
//  of its 코드표) is in attributes of its own namespace, which a standard
//  reader passes over.
//
//  Changes go as XFDF too: the <add>, <modify> and <delete> form that
//  PDF tools use to send one person's edits to another's copy — what the
//  devices in the room send each other (RehearsalLink).
//
//  Foundation only — Tools/check-xfdf.swift runs it.
//

import Foundation
import CoreGraphics

enum XFDF {

    /// This app's attributes, apart from the standard's.
    static let namespace = "https://solapraise.app/xfdf/1"

    /// One chord on one page.
    struct Mark: Equatable {
        var name: String
        /// The page of the chart this is on, from 0 — of a 콘티 file's song,
        /// its own pages; `pdfPage` is which page of the file that is.
        var part: Int
        /// Where it was found, as a share of the page, origin top-left.
        var box: CGRect
        /// Where the reader dragged it since, likewise.
        var offset: CGSize = .zero
        /// The chord as printed in the chart's key.
        var text: String
        var userAdded = false
        var corrected: Bool? = nil

        /// Shown by any reader: someone did something to it.
        var isChange: Bool { userAdded || corrected == true || offset != .zero }
    }

    /// A word of the 코드표 corrected, by its place in this app's reading.
    struct Lyric: Equatable {
        var system: Int, bar: Int, cell: Int, verse: Int
        var from: String, to: String
    }

    struct Document: Equatable {
        /// Per page of the chart, in order — empty pages included.
        var pages: [[Mark]]
        var lyrics: [Lyric] = []
    }

    // MARK: - Writing

    /// - pdfPages: which page of the file each page of the chart is.
    /// - sizes: each page's size in points, for the standard's rectangle;
    ///   US Letter where not known — this app reads its own box.
    static func encode(_ document: Document, pdfPages: [Int], sizes: [CGSize]) -> String {
        var out = header + "<annots sp:pages=\"\(document.pages.count)\">"
        for (part, marks) in document.pages.enumerated() {
            for mark in marks {
                out += element(mark, pdfPages: pdfPages, sizes: sizes)
            }
        }
        for lyric in document.lyrics { out += element(lyric) }
        return out + "</annots></xfdf>"
    }

    /// Changes only: chords added, changed and taken off.
    static func command(add: [Mark], modify: [Mark], delete: [Mark], pdfPages: [Int], sizes: [CGSize]) -> String {
        var out = header
        if !add.isEmpty { out += "<add>" + add.map { element($0, pdfPages: pdfPages, sizes: sizes) }.joined() + "</add>" }
        if !modify.isEmpty { out += "<modify>" + modify.map { element($0, pdfPages: pdfPages, sizes: sizes) }.joined() + "</modify>" }
        if !delete.isEmpty {
            // The standard names the annotation and its page; the box goes
            // with it so a copy read under other names can find it by place.
            out += "<delete>" + delete.map { mark in
                "<id page=\"\(page(of: mark, pdfPages))\" sp:part=\"\(mark.part)\" sp:box=\"\(numbers(mark.box))\">\(escape(mark.name))</id>"
            }.joined() + "</delete>"
        }
        return out + "</xfdf>"
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\" xmlns:sp=\"\(namespace)\" xml:space=\"preserve\">"

    private static func page(of mark: Mark, _ pdfPages: [Int]) -> Int {
        pdfPages.indices.contains(mark.part) ? pdfPages[mark.part] : mark.part
    }

    private static func element(_ mark: Mark, pdfPages: [Int], sizes: [CGSize]) -> String {
        let size = sizes.indices.contains(mark.part) ? sizes[mark.part] : CGSize(width: 612, height: 792)
        let placed = mark.box.offsetBy(dx: mark.offset.width, dy: mark.offset.height)
        // PDF space: points, origin bottom-left.
        let rect = CGRect(x: placed.minX * size.width, y: (1 - placed.maxY) * size.height,
                          width: placed.width * size.width, height: placed.height * size.height)
        var attributes = [
            "page=\"\(page(of: mark, pdfPages))\"",
            "rect=\"\(points(rect.minX)),\(points(rect.minY)),\(points(rect.maxX)),\(points(rect.maxY))\"",
            "name=\"\(escape(mark.name))\"",
            "subject=\"chord\"",
            "sp:part=\"\(mark.part)\"",
            "sp:box=\"\(numbers(mark.box))\""
        ]
        if !mark.isChange { attributes.append("flags=\"hidden\"") }
        if mark.offset != .zero { attributes.append("sp:offset=\"\(number(mark.offset.width)),\(number(mark.offset.height))\"") }
        if mark.userAdded { attributes.append("sp:added=\"1\"") }
        if let corrected = mark.corrected { attributes.append("sp:corrected=\"\(corrected ? 1 : 0)\"") }
        return "<freetext \(attributes.joined(separator: " "))><contents>\(escape(mark.text))</contents></freetext>"
    }

    private static func element(_ lyric: Lyric) -> String {
        "<freetext page=\"0\" rect=\"0,0,0,0\" flags=\"hidden\" subject=\"lyric\""
            + " sp:system=\"\(lyric.system)\" sp:bar=\"\(lyric.bar)\" sp:cell=\"\(lyric.cell)\" sp:verse=\"\(lyric.verse)\""
            + " sp:from=\"\(escape(lyric.from))\"><contents>\(escape(lyric.to))</contents></freetext>"
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.5f", Double(value))
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func points(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }

    private static func numbers(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height].map(number).joined(separator: ",")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Reading

    /// A document, or nil when the text is not XFDF.
    static func decode(_ xml: String) -> Document? {
        let reader = Reader()
        guard reader.read(xml), reader.sawXFDF else { return nil }
        var pages = [[Mark]](repeating: [], count: max(reader.pageCount ?? 0, (reader.marks.map(\.part).max() ?? -1) + 1))
        for mark in reader.marks { pages[mark.part].append(mark) }
        return Document(pages: pages, lyrics: reader.lyrics)
    }

    /// A command's three lists, or nil when the text is not XFDF.
    static func decodeCommand(_ xml: String) -> (add: [Mark], modify: [Mark], delete: [Mark])? {
        let reader = Reader()
        guard reader.read(xml), reader.sawXFDF else { return nil }
        return (reader.added, reader.modified, reader.deleted)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var marks: [Mark] = [], added: [Mark] = [], modified: [Mark] = [], deleted: [Mark] = []
        var lyrics: [Lyric] = []
        var pageCount: Int?
        var sawXFDF = false
        private var section = ""
        private var pending: [String: String]?
        private var pendingKind = ""
        private var text = ""

        func read(_ xml: String) -> Bool {
            let parser = XMLParser(data: Data(xml.utf8))
            parser.shouldProcessNamespaces = false
            parser.delegate = self
            return parser.parse()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "xfdf": sawXFDF = true
            case "annots":
                section = "annots"
                pageCount = attributes["sp:pages"].flatMap(Int.init)
            case "add", "modify", "delete": section = name
            case "freetext", "id":
                pending = attributes
                pendingKind = name
                text = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if pending != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == pendingKind, let attributes = pending else { return }
            pending = nil
            if pendingKind == "id" {
                deleted.append(Mark(name: text, part: Int(attributes["sp:part"] ?? "") ?? Int(attributes["page"] ?? "") ?? 0,
                                    box: rect(attributes["sp:box"]) ?? .zero, text: ""))
                return
            }
            if attributes["subject"] == "lyric" {
                lyrics.append(Lyric(system: int(attributes["sp:system"]), bar: int(attributes["sp:bar"]),
                                    cell: int(attributes["sp:cell"]), verse: int(attributes["sp:verse"]),
                                    from: attributes["sp:from"] ?? "", to: text))
                return
            }
            let offset = attributes["sp:offset"].map { value -> CGSize in
                let parts = value.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : .zero
            } ?? .zero
            let mark = Mark(name: attributes["name"] ?? "",
                            part: Int(attributes["sp:part"] ?? "") ?? Int(attributes["page"] ?? "") ?? 0,
                            box: rect(attributes["sp:box"]) ?? .zero, offset: offset,
                            text: text,
                            userAdded: attributes["sp:added"] == "1",
                            corrected: attributes["sp:corrected"].map { $0 == "1" })
            switch section {
            case "add": added.append(mark)
            case "modify": modified.append(mark)
            default: marks.append(mark)
            }
        }

        private func int(_ value: String?) -> Int { value.flatMap(Int.init) ?? 0 }

        private func rect(_ value: String?) -> CGRect? {
            guard let parts = value?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4 else { return nil }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
    }
}
