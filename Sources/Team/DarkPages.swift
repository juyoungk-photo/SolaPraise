//
//  DarkPages.swift
//  SolaPraise
//
//  악보 어둡게 보기 (베타): the chart's page shown light on black — its
//  notes, words and chords white on a dark stand, as the 코드표 already is.
//
//  The page image is inverted, then its hues turned half round, so a red
//  mark stays red and a blue chord blue while black becomes white. On
//  screen only: a PDF, a photo, a print stay as the page is.
//
//  Made once per page, off the main thread, and kept. It was a filter on
//  the whole page as drawn — image, chords, drawings — which the system
//  renders offscreen on every frame, and the stand took seconds to open.
//  The chords and drawings laid on the page are now drawn dark themselves.
//
//  오선·음표 밝기: what a player reads is the chords and the words. The
//  staves — lines, notes, stems — are found on the page (the same finder
//  the chord reader uses) and shaded to a grey the player chooses, so the
//  words below them and the chords above stand out. A page with no staff,
//  a lyric sheet, has nothing to shade.
//
//  The shade reaches well past the staff, for notes hung below it and
//  the line a faint scan loses (the finder takes four lines for a staff),
//  and the words caught in it — a lyric close under the staff, a chord
//  just over it — are cut back out, found as text by Vision.
//

import SwiftUI
import CoreImage
import Vision

enum DarkPages {
    static let key = "score.darkPages"
    /// How bright the staves stay in the dark: 1 as the words, down to a
    /// faint grey.
    static let staffKey = "score.darkStaffLevel"
    static let staffRange: ClosedRange<Double> = 0.2...1
}

/// The dark page and its staves, made once per page image.
final class DarkPageRenderer: @unchecked Sendable {
    static let shared = DarkPageRenderer()

    struct Result {
        let image: UIImage
        /// The staves to shade, normalised to the page (top-left origin),
        /// each reaching past its outer lines for the notes just off them.
        let staves: [CGRect]
        /// The words in or near them, kept bright.
        let words: [CGRect]
    }

    private let cache = NSCache<UIImage, Box>()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private final class Box { let result: Result; init(_ r: Result) { result = r } }

    private init() { cache.countLimit = 40 }

    func cached(_ page: UIImage) -> Result? { cache.object(forKey: page)?.result }

    func render(_ page: UIImage) async -> Result? {
        if let done = cached(page) { return done }
        let result = await Task.detached(priority: .userInitiated) { [context] () -> Result? in
            guard let cg = page.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            guard let invert = CIFilter(name: "CIColorInvert"),
                  let hue = CIFilter(name: "CIHueAdjust") else { return nil }
            invert.setValue(input, forKey: kCIInputImageKey)
            hue.setValue(invert.outputImage, forKey: kCIInputImageKey)
            hue.setValue(Float.pi, forKey: kCIInputAngleKey)
            guard let output = hue.outputImage,
                  let dark = context.createCGImage(output, from: input.extent) else { return nil }
            let found = ScoreRecognition.staves(in: cg).map(\.staff)
            let staves = found.map { staff -> CGRect in
                let space = staff.height / 4
                return CGRect(x: 0, y: staff.minY - space * 1.5,
                              width: 1, height: staff.height + space * 4.5)
            }
            // Words near a staff, never between its lines: no lyric or
            // chord sits there, and Vision takes a run of beamed notes —
            // or a chord with the notes under it — for a word. What of a
            // box lies above or below the lines is kept.
            let words = staves.isEmpty ? [] : Self.words(in: cg)
                .filter { word in staves.contains { $0.intersects(word) } }
                .flatMap { word in found.reduce([word]) { pieces, staff in
                    // A space below too: the line the finder may have
                    // missed, and the notes hung on it.
                    let space = staff.height / 4
                    let lines = CGRect(x: 0, y: staff.minY - space * 0.25,
                                       width: 1, height: staff.height + space * 1.5)
                    return pieces.flatMap { Self.outside(lines, $0) }
                } }
            return Result(image: UIImage(cgImage: dark, scale: page.scale, orientation: page.imageOrientation),
                          staves: staves, words: words)
        }.value
        if let result { cache.setObject(Box(result), forKey: page) }
        return result
    }

    /// The parts of `word` above and below a staff's lines.
    private static func outside(_ staff: CGRect, _ word: CGRect) -> [CGRect] {
        guard word.intersects(staff) else { return [word] }
        var parts: [CGRect] = []
        if word.minY < staff.minY {
            parts.append(CGRect(x: word.minX, y: word.minY, width: word.width, height: staff.minY - word.minY))
        }
        if word.maxY > staff.maxY {
            parts.append(CGRect(x: word.minX, y: staff.maxY, width: word.width, height: word.maxY - staff.maxY))
        }
        return parts
    }

    /// Where the page has words — any script, nothing read — normalised,
    /// top-left origin, a little padded.
    private static func words(in image: CGImage) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { found in
            let box = found.boundingBox
            let pad = box.height * 0.15
            return CGRect(x: box.minX - pad, y: 1 - box.maxY - pad,
                          width: box.width + pad * 2, height: box.height + pad * 2)
        }
    }
}

/// The page image, dark when 어둡게 보기 is on: the made dark page with its
/// staves shaded, or — for the moment before it is made — the page
/// filtered on screen, never a white flash on a dark stand.
struct DarkPageImage: View {
    let image: UIImage
    let dark: Bool

    @AppStorage(DarkPages.staffKey) private var staffLevel = 0.45
    @State private var made: DarkPageRenderer.Result?

    var body: some View {
        Group {
            if !dark {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let made = made ?? DarkPageRenderer.shared.cached(image) {
                Image(uiImage: made.image).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        if staffLevel < 0.99, !made.staves.isEmpty {
                            Canvas { context, size in
                                func scaled(_ r: CGRect) -> CGRect {
                                    CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                           width: r.width * size.width, height: r.height * size.height)
                                }
                                // Everything but the words, then the staves in it.
                                var keep = Path(CGRect(origin: .zero, size: size))
                                for word in made.words { keep.addRect(scaled(word)) }
                                context.clip(to: keep, style: FillStyle(eoFill: true))
                                var shade = Path()
                                for staff in made.staves { shade.addRect(scaled(staff)) }
                                context.fill(shade, with: .color(.black.opacity(1 - staffLevel)))
                            }
                            .allowsHitTesting(false)
                        }
                    }
            } else {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .colorInvert().hueRotation(.degrees(180))
            }
        }
        .task(id: dark ? ObjectIdentifier(image) : nil) {
            guard dark else { return }
            made = await DarkPageRenderer.shared.render(image)
        }
    }
}

/// 🌙 on the stand's header: 악보 어둡게 보기, where it is seen. It was in
/// 설정 and at the foot of the 저장·공유 menu, and could not be found.
/// Off, a tap turns it on; on, a tap opens the 오선·음표 밝기 knob, with
/// the way back to a light page beside it.
struct DarkPagesButton: View {
    @AppStorage(DarkPages.key) private var on = false
    @State private var adjusting = false

    var body: some View {
        Button {
            if on { adjusting = true } else { on = true }
        } label: {
            Image(systemName: on ? "moon.fill" : "moon")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 30)
                .background(on ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(on ? "오선·음표 밝기, 악보 밝게 보기" : "악보 어둡게 보기 (베타)")
        .popover(isPresented: $adjusting) {
            DarkPagesPanel(onLight: { on = false; adjusting = false })
                .padding(16)
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The knob: how bright the staves stay, so the chords and words stand
/// out. Seen on the page behind it as it moves.
struct DarkPagesPanel: View {
    var onLight: (() -> Void)?
    @AppStorage(DarkPages.staffKey) private var staffLevel = 0.45

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("오선·음표 밝기").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                Slider(value: $staffLevel, in: DarkPages.staffRange)
                Image(systemName: "music.note").font(.title3)
            }
            Text("오선과 음표를 흐리게 하면 코드와 가사가 더 잘 보입니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let onLight {
                Button(action: onLight) {
                    Label("악보 밝게 보기", systemImage: "sun.max")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
