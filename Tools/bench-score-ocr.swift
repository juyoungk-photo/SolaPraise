//
//  bench-score-ocr.swift
//  SolaPraise
//
//  Scores the chord recogniser against real charts with hand-written
//  ground truth — the team's own uploads, kept outside the repository.
//
//  WHY THIS EXISTS: check-score-ocr.swift draws its own pages, and the
//  recogniser passed every one of them while reading 「F♯m」 as 「Fm」 and
//  「C9」 as 「C°」 on charts the team actually uses. Synthetic pages test
//  what we thought of; real ones test what printers, scanners and fonts
//  do. A change to recognition is judged here — found, wrong, missing —
//  before and after, on every chart, not on the one it was written for.
//
//  Layout of the directory (nothing from it is ever committed):
//      <dir>/<name>.jpg|png|pdf        the chart
//      <dir>/gt/<name>.txt             one line per chord row:
//                                      <y> <chord>@<x> <chord>@<x> …
//                                      (normalised, origin top-left; a
//                                      chord written 「?」 is not scored)
//
//  Run:
//      swiftc -O -o /tmp/benchocr \
//          Sources/Chords/ScoreChordText.swift Sources/Chords/ScoreRecognition.swift Sources/Chords/ChordGlyphs.swift \
//          Tools/bench-score-ocr.swift
//      /tmp/benchocr <dir> [name …]          (-v lists every miss)
//

import Foundation
import AppKit
import PDFKit

@main
struct BenchScoreOCR {
    struct Truth { let y: CGFloat; let x: CGFloat; let text: String }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        let verbose = args.contains("-v")
        args.removeAll { $0 == "-v" }
        guard let dir = args.first else { print("usage: benchocr <dir> [name …] [-v]"); exit(2) }
        let only = Set(args.dropFirst())
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir + "/gt")) ?? [])
            .filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) }.sorted()
            .filter { only.isEmpty || only.contains($0) }
        guard !names.isEmpty else { print("no gt/*.txt in \(dir)"); exit(2) }

        var totalTruth = 0, totalRight = 0, totalWrong = 0, totalExtra = 0
        let started = Date()
        for name in names {
            guard let truth = loadTruth("\(dir)/gt/\(name).txt"),
                  let image = loadImage(dir, name) else { print("\(name): cannot load"); continue }
            let t0 = Date()
            let found = ScoreRecognition.chords(in: image)
            let seconds = Date().timeIntervalSince(t0)

            // Each truth takes the nearest found chord on its row; what is
            // left over was read where nothing is printed.
            var taken = Set<UUID>()
            var right = 0, wrong = 0
            var misses: [String] = []
            for want in truth {
                let candidates = found.filter { !taken.contains($0.id) && abs($0.box.midY - want.y) < 0.02
                    && abs($0.box.minX - want.x) < 0.04 }
                if let hit = candidates.min(by: { abs($0.box.minX - want.x) < abs($1.box.minX - want.x) }) {
                    taken.insert(hit.id)
                    if same(hit.original, want.text) { right += 1 }
                    else { wrong += 1; misses.append("\(want.text)@\(fmt(want.x)),\(fmt(want.y)) read as \(hit.original)") }
                } else if want.text != "?" {
                    misses.append("\(want.text)@\(fmt(want.x)),\(fmt(want.y)) missing")
                }
            }
            let scored = truth.filter { $0.text != "?" }.count
            // A read with no printed chord near it. Not counted against a
            // 「?」, which is printed but unreadable.
            let extra = found.filter { f in !taken.contains(f.id)
                && !truth.contains { $0.text == "?" && abs(f.box.midY - $0.y) < 0.02 && abs(f.box.minX - $0.x) < 0.04 } }
            let missing = scored - right - wrong
            print(String(format: "%-8@ %3d printed  %3d right  %2d wrong  %2d missing  %2d extra   %.1fs",
                         name as NSString, scored, right, wrong, missing, extra.count, seconds))
            if verbose {
                for line in misses { print("           \(line)") }
                for f in extra { print("           extra \(f.original)@\(fmt(f.box.minX)),\(fmt(f.box.midY))") }
            }
            totalTruth += scored; totalRight += right; totalWrong += wrong; totalExtra += extra.count
        }
        let missing = totalTruth - totalRight - totalWrong
        print(String(format: "\ntotal    %3d printed  %3d right  %2d wrong  %2d missing  %2d extra   %.0f%% right   %.0fs",
                     totalTruth, totalRight, totalWrong, missing, totalExtra,
                     totalTruth > 0 ? Double(totalRight) * 100 / Double(totalTruth) : 0,
                     Date().timeIntervalSince(started)))
    }

    /// 「F#m」 and 「F♯m」 are the same chord; so are 「Bb」 and 「B♭」.
    static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
                .replacingOccurrences(of: " ", with: "")
        }
        return norm(a) == norm(b)
    }

    static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    static func loadTruth(_ path: String) -> [Truth]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var out: [Truth] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard let first = parts.first, let y = Double(first) else { continue }
            for token in parts.dropFirst() {
                let halves = token.split(separator: "@")
                guard halves.count == 2, let x = Double(halves[1]) else { continue }
                out.append(Truth(y: CGFloat(y), x: CGFloat(x), text: String(halves[0])))
            }
        }
        return out
    }

    static func loadImage(_ dir: String, _ name: String) -> CGImage? {
        for ext in ["jpg", "jpeg", "png", "pdf"] {
            let path = "\(dir)/\(name).\(ext)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if ext == "pdf" {
                guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let scale = 2000 / max(bounds.width, bounds.height)
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let image = NSImage(size: size)
                image.lockFocus()
                NSColor.white.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                image.unlockFocus()
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            return NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }
}
