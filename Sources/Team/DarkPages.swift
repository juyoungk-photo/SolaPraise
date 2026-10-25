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
//  The shade covers each staff and the ink joined to it, pixel by pixel,
//  and never the words or chords beside it (StaffShade). Still a beta, so
//  it has its own switch beside its knob: a chart it reads badly can be
//  shown plain.
//

import SwiftUI
import CoreImage

enum DarkPages {
    static let key = "score.darkPages"
    /// How bright the staves stay in the dark: 1 as the words, down to a
    /// faint grey.
    static let staffKey = "score.darkStaffLevel"
    static let staffRange: ClosedRange<Double> = 0.2...1
    /// Whether the staves are shaded at all.
    static let staffOnKey = "score.darkStaffShade"
}

/// The dark page and its staves, made once per page image.
final class DarkPageRenderer: @unchecked Sendable {
    static let shared = DarkPageRenderer()

    struct Result {
        let image: UIImage
        /// Black where the staves and the notes joined to them are, clear
        /// elsewhere, the page's size: laid over the page at the knob's
        /// strength. Nil on a page with no staff.
        let shade: UIImage?
    }

    private let cache = NSCache<UIImage, Box>()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private final class Box { let result: Result; init(_ r: Result) { result = r } }

    /// A dark page is the page's size in colour, its shade a quarter of
    /// that: kept within a few charts' worth.
    private init() { cache.totalCostLimit = 300 * 1024 * 1024 }

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
            let shade = found.isEmpty ? nil : ScoreRecognition.grayscale(cg).flatMap {
                Self.shadeImage(StaffShade.mask(gray: $0, width: cg.width, height: cg.height, staves: found),
                                width: cg.width, height: cg.height)
            }
            return Result(image: UIImage(cgImage: dark, scale: page.scale, orientation: page.imageOrientation),
                          shade: shade.map { UIImage(cgImage: $0, scale: page.scale, orientation: page.imageOrientation) })
        }.value
        if let result, let cg = result.image.cgImage {
            cache.setObject(Box(result), forKey: page, cost: cg.width * cg.height * 6)
        }
        return result
    }

    /// Black, its alpha the mask: grey and alpha, two bytes a pixel.
    private static func shadeImage(_ mask: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 2)
        for i in 0..<(width * height) { bytes[i * 2 + 1] = mask[i] }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: width * 2,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The page image, dark when 어둡게 보기 is on: the made dark page with its
/// staves shaded, or — for the moment before it is made — the page
/// filtered on screen, never a white flash on a dark stand.
struct DarkPageImage: View {
    let image: UIImage
    let dark: Bool

    @AppStorage(DarkPages.staffKey) private var staffLevel = 0.45
    @AppStorage(DarkPages.staffOnKey) private var shading = true
    @State private var made: DarkPageRenderer.Result?

    var body: some View {
        Group {
            if !dark {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let made = made ?? DarkPageRenderer.shared.cached(image) {
                Image(uiImage: made.image).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        if shading, staffLevel < 0.99, let shade = made.shade {
                            // As dark as the knob says.
                            Image(uiImage: shade).resizable().aspectRatio(contentMode: .fit)
                                .opacity(1 - staffLevel)
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
                .foregroundStyle(.white)
                .frame(width: 34, height: 30)
                .background(on ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "오선·음표 밝기, 악보 밝게 보기" : "악보 어둡게 보기 (베타)")
        // White on the button only: set on the button, it reached the
        // popover's text, which then vanished on a light popover.
        .popover(isPresented: $adjusting) {
            DarkPagesPanel(onLight: { on = false; adjusting = false })
                .padding(16)
                .frame(width: 300)
                .preferredColorScheme(.dark)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The knob: whether the staves are shaded, and how far, so the chords
/// and words stand out. Seen on the page behind it as it moves.
struct DarkPagesPanel: View {
    var onLight: (() -> Void)?
    @AppStorage(DarkPages.staffKey) private var staffLevel = 0.45
    @AppStorage(DarkPages.staffOnKey) private var shading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $shading) {
                Text("오선·음표 흐리게 (베타)").font(.headline)
            }
            HStack(spacing: 10) {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                Slider(value: $staffLevel, in: DarkPages.staffRange)
                Image(systemName: "music.note").font(.title3)
            }
            .disabled(!shading)
            .opacity(shading ? 1 : 0.4)
            Text(shading
                 ? "오선과 음표를 흐리게 하면 코드와 가사가 더 잘 보입니다. 이상하게 보이는 악보면 끄세요."
                 : "악보를 그대로 어둡게 보여 줍니다.")
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
