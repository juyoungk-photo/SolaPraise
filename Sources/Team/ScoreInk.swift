//
//  ScoreInk.swift
//  SolaPraise
//
//  그리기: marks drawn on a chart with Apple Pencil or a finger — a circled
//  bar, an arrow back to the bridge, 「rit.」, a breath — each member's on a
//  layer of their own, seen on every stand.
//
//  WHY LAYERS: two people drawing on one chart at once must not write over
//  each other, and an eraser in one hand must not take another's marks.
//  So each member's strokes are theirs: kept, shared and erased as one
//  layer, drawn under everyone else's.
//
//  To the stands in the room a page goes as PencilKit drew it — pressure,
//  texture, a highlighter's wash — and is drawn there as drawn; a stand
//  that comes in later is sent each member's pages then. The drawer's own
//  canvas, and a PDF made from it, keep the drawing as drawn — that PDF is
//  how it reaches anyone not in the room. The strokes also go as XFDF
//  <ink>, the standard form PDF apps use for hand-drawn marks, for the
//  annotated-PDF and XFDF exports.
//
//  Drawn as on paper: the page is white whatever the app's appearance, so
//  ink is never turned light for dark mode — black stays black.
//

import SwiftUI
import UIKit
import PencilKit
import CryptoKit

/// Converting between PencilKit's drawing and the strokes as shared.
enum InkBridge {

    /// A canvas's drawing as strokes on a page `size` points across.
    static func strokes(from drawing: PKDrawing, size: CGSize, part: Int) -> [XFDF.Ink] {
        guard size.width > 0, size.height > 0 else { return [] }
        return drawing.strokes.enumerated().compactMap { index, stroke in
            let points = stroke.path.interpolatedPoints(by: .distance(2)).map { point -> CGPoint in
                let at = point.location.applying(stroke.transform)
                return CGPoint(x: at.x / size.width, y: at.y / size.height)
            }
            guard points.count > 1 else { return nil }
            let widths = stroke.path.map(\.size.width)
            let width = (widths.reduce(0, +) / CGFloat(max(widths.count, 1))) / size.width
            let marker = stroke.ink.inkType == .marker
            return XFDF.Ink(name: "p\(part)s\(index)", part: part, points: points, width: width,
                            color: hex(stroke.ink.color), opacity: marker ? 0.35 : 1, marker: marker)
        }
    }

    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    static func color(_ hex: String) -> UIColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return .black }
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// A page as PencilKit drew it, and the size it was drawn at — so it is
/// laid on a page of another size, on another device, at its place.
struct RichPage: Codable, Equatable {
    var data: Data
    var width: CGFloat
    var height: CGFloat

    /// Which drawing this is, to tell a new one from the one shown.
    var key: String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The drawing, scaled to a page `size` points across.
    func drawing(for size: CGSize) -> PKDrawing? {
        guard let drawing = try? PKDrawing(data: data), width > 0 else { return nil }
        let scale = size.width / width
        return abs(scale - 1) < 0.001 ? drawing : drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// Every layer of a chart kept on the device: this member's, and each
/// other member's as last heard — by chart (the stand item's id).
enum ScoreInkStore {
    struct Layers: Codable, Equatable {
        /// The drawer's own pages as PencilKit keeps them — pressure,
        /// texture and all — by page: what their own canvas shows, and what
        /// goes to the stands in the room.
        var mineDrawings: [String: RichPage] = [:]
        /// Other members' pages as their PencilKit drew them, heard from the
        /// room: author → page → drawing. Drawn instead of their strokes.
        var rich: [String: [String: RichPage]] = [:]

        /// Every page drawn on, by whom — this member's own as `mine`.
        var all: [(author: String, page: Int, drawing: RichPage)] {
            mineDrawings.compactMap { key, page in Int(key).map { (ScoreInkStore.mine, $0, page) } }
                + rich.flatMap { author, pages in
                    pages.compactMap { key, page in Int(key).map { (author, $0, page) } }
                }
        }

        /// Everyone's strokes as XFDF <ink>, worked out of the drawings —
        /// only when an export asks: drawing and sending need none of it.
        func strokes(page: Int? = nil) -> [XFDF.Ink] {
            all.filter { page == nil || $0.page == page }.flatMap { _, page, rich -> [XFDF.Ink] in
                guard let drawing = try? PKDrawing(data: rich.data) else { return [] }
                return InkBridge.strokes(from: drawing, size: CGSize(width: rich.width, height: rich.height), part: page)
            }
        }
    }

    static let mine = "mine"

    private static var folder: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("ScoreInk", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func load(_ id: String) -> Layers {
        guard let url = ScoreEditStore.file(id, in: folder), let data = try? Data(contentsOf: url),
              let layers = try? JSONDecoder().decode(Layers.self, from: data) else { return Layers() }
        return layers
    }

    static func save(_ layers: Layers, for id: String) {
        guard let url = ScoreEditStore.file(id, in: folder), let data = try? JSONEncoder().encode(layers) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The drawer's own layer on one page, to draw on: PencilKit's canvas with
/// its tool picker, transparent over the page.
struct InkCanvas: UIViewRepresentable {
    /// The drawer's own page as PencilKit keeps it.
    let drawing: RichPage?
    let active: Bool
    let onChange: (RichPage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> PageCanvas {
        let canvas = PageCanvas()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        // Laid in when the canvas first has its size, and again when turned.
        canvas.onLayout = { [weak coordinator = context.coordinator] canvas in
            coordinator?.load(canvas, sizeOnly: true)
        }
        // Pencil, and a finger where there is no pencil — the system's own
        // 「Only Draw with Apple Pencil」 decides.
        canvas.drawingPolicy = .default
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 3)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PageCanvas, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        coordinator.drawing = drawing
        canvas.isUserInteractionEnabled = active
        // Again when what it holds came from elsewhere.
        coordinator.load(canvas, sizeOnly: false)
        let picker = Self.picker
        picker.addObserver(canvas)
        picker.setVisible(active, forFirstResponder: canvas)
        if active { canvas.becomeFirstResponder() } else if canvas.isFirstResponder { canvas.resignFirstResponder() }
    }

    static func dismantleUIView(_ canvas: PageCanvas, coordinator: Coordinator) {
        picker.setVisible(false, forFirstResponder: canvas)
        picker.removeObserver(canvas)
    }

    /// One tool picker for every page: the pen chosen on one is the pen on
    /// the next.
    static let picker: PKToolPicker = {
        let picker = PKToolPicker()
        // Its colours as they will look on the page.
        picker.colorUserInterfaceStyle = .light
        picker.selectedTool = PKInkingTool(.pen, color: .systemRed, width: 3)
        return picker
    }()

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (RichPage) -> Void
        var loaded = ""
        var size: CGSize = .zero
        var loading = false
        var drawing: RichPage?

        init(onChange: @escaping (RichPage) -> Void) { self.onChange = onChange }

        private var key: String { drawing.map { "d" + $0.key } ?? "none" }

        /// What it holds, at this page's size now — turned, or on another
        /// screen. On a layout only when the size changed, so a stroke
        /// being drawn is never put back to what was last saved.
        func load(_ canvas: PKCanvasView, sizeOnly: Bool) {
            let size = canvas.bounds.size
            guard size.width > 0, size != self.size || (!sizeOnly && loaded != key) else { return }
            loading = true
            canvas.drawing = drawing?.drawing(for: size) ?? PKDrawing()
            loading = false
            loaded = key
            self.size = size
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !loading else { return }
            let size = canvasView.bounds.size
            let page = RichPage(data: canvasView.drawing.dataRepresentation(), width: size.width, height: size.height)
            loaded = "d" + page.key
            onChange(page)
        }
    }
}

/// Another member's page as their PencilKit drew it: drawn as drawn.
struct InkRichView: UIViewRepresentable {
    let page: RichPage

    func makeUIView(context: Context) -> PageCanvas {
        let canvas = PageCanvas()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isUserInteractionEnabled = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.onLayout = { [weak coordinator = context.coordinator] canvas in coordinator?.load(canvas) }
        return canvas
    }

    func updateUIView(_ canvas: PageCanvas, context: Context) {
        context.coordinator.page = page
        context.coordinator.load(canvas)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var page: RichPage?
        var key = ""

        func load(_ canvas: PKCanvasView) {
            let size = canvas.bounds.size
            guard size.width > 0, let page else { return }
            let key = "\(page.key)|\(size.width)"
            guard self.key != key else { return }
            self.key = key
            canvas.drawing = page.drawing(for: size) ?? PKDrawing()
        }
    }
}

/// A canvas that says when it is laid out: SwiftUI sets a view up before
/// it has a size, and a drawing laid in then would be at no size at all.
final class PageCanvas: PKCanvasView {
    var onLayout: ((PageCanvas) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

/// A page's drawing as one image the page's size — everyone's marks, the
/// drawer's own as drawn — to lay over it in a PDF or a photo.
enum InkRender {
    static func image(_ ink: PageInk, size: CGSize) -> UIImage? {
        guard !ink.othersRich.isEmpty || ink.mineDrawing != nil else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        // As on paper, whatever the app's appearance.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = render(ink, size: size, format: format)
        }
        return image
    }

    private static func render(_ ink: PageInk, size: CGSize, format: UIGraphicsImageRendererFormat) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            for rich in ink.othersRich {
                rich.drawing(for: size)?.image(from: bounds, scale: 3).draw(in: bounds)
            }
            if let mine = ink.mineDrawing?.drawing(for: size) {
                mine.image(from: bounds, scale: 3).draw(in: bounds)
            }
        }
    }
}
