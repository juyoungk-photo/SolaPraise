//
//  ScoreRecognition.swift
//  SolaPraise
//
//  Finding the chord symbols on one page image, and where each one sits.
//
//  Kept to Vision and CoreGraphics — no UIKit — so the same code that runs
//  in the app can be run against a rendered test page on the Mac. See
//  Tools/check-score-ocr.swift. A recogniser that quietly misses chords
//  looks exactly like a score that has none, so it needs a check that can
//  fail.
//

import Foundation
import Vision
import CoreGraphics

enum ScoreRecognition {

    /// One chord found on a page.
    struct Found: Identifiable, Equatable {
        let id = UUID()
        let original: String
        /// Normalised image coordinates, origin top-left.
        let box: CGRect
        let confidence: Float

        static func == (l: Found, r: Found) -> Bool { l.id == r.id }
    }

    /// Every chord symbol on the page.
    ///
    /// Several passes, merged. Vision is unreliable on a lone capital —
    /// a "C" by itself on a line is often not reported as text at all, and
    /// which lone letters it drops changes with the language order and the
    /// size of the image around them. Measured on a rendered page: one
    /// full-page pass missed every isolated C; the Korean-first order found
    /// some; a strip cropped to a single chord line found the rest. So:
    ///
    /// 1. the whole page, English first, then Korean first;
    /// 2. a strip across every chord line found so far, and across the
    ///    space just above every lyric line — where chords sit on a lead
    ///    sheet even when the first passes found none on that line.
    ///
    /// Results are merged by position, so a chord found twice is kept once.
    static func chords(in image: CGImage) -> [Found] {
        var found: [Found] = []
        var lyricLines: [CGRect] = []

        for languages in [["en-US", "ko-KR"], ["ko-KR", "en-US"]] {
            let pass = recognise(image, languages: languages)
            merge(pass.chords, into: &found)
            lyricLines += pass.lyricLines
        }

        for band in bands(chords: found, lyricLines: lyricLines) {
            let pixels = CGRect(x: 0,
                                y: band.minY * CGFloat(image.height),
                                width: CGFloat(image.width),
                                height: band.height * CGFloat(image.height)).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            let pass = recognise(crop, languages: ["ko-KR", "en-US"])
            // Back from the strip's coordinates to the page's.
            let mapped = pass.chords.map { item in
                Found(original: item.original,
                      box: CGRect(x: item.box.minX,
                                  y: band.minY + item.box.minY * band.height,
                                  width: item.box.width,
                                  height: item.box.height * band.height),
                      confidence: item.confidence)
            }
            merge(mapped, into: &found)
        }
        return found.sorted {
            abs($0.box.minY - $1.box.minY) > 0.01 ? $0.box.minY < $1.box.minY
                                                   : $0.box.minX < $1.box.minX
        }
    }

    /// One recognition pass: the chords it read, and the lines of Hangul,
    /// which mark where lyrics are and so where chords should be above.
    private static func recognise(_ image: CGImage,
                                  languages: [String]) -> (chords: [Found], lyricLines: [CGRect]) {
        let request = VNRecognizeTextRequest()
        // Accurate, not fast: chord symbols are small and this runs once
        // per page rather than per frame.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // "Am" must not become "An"
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return ([], []) }

        var chords: [Found] = []
        var lyrics: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                let b = observation.boundingBox
                lyrics.append(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
            let words = wordRanges(in: text)
            for range in words {
                var word = String(text[range])
                // A lone lowercase letter standing on its own is a chord
                // Vision has lowered — "c" for C — since a Korean chart
                // has no English one-letter words. Never "b", which is a
                // flat sign as often as anything.
                if words.count == 1, word.count == 1, "acdefg".contains(word) {
                    word = word.uppercased()
                }
                guard ScoreChordText.parse(word) != nil else { continue }
                let box = (try? candidate.boundingBox(for: range))?.boundingBox
                    ?? estimatedBox(of: range, in: text, line: observation.boundingBox)
                chords.append(Found(
                    original: word,
                    // Vision's origin is bottom-left; flip it so the box
                    // can be drawn straight onto the image.
                    box: CGRect(x: box.minX, y: 1 - box.maxY,
                                width: box.width, height: box.height),
                    confidence: candidate.confidence))
            }
        }
        return (chords, lyrics)
    }

    /// Adds what is new, by position: a box whose centre falls inside one
    /// already found is the same chord read again.
    private static func merge(_ incoming: [Found], into found: inout [Found]) {
        for item in incoming {
            let centre = CGPoint(x: item.box.midX, y: item.box.midY)
            let duplicate = found.contains { existing in
                existing.box.insetBy(dx: -0.004, dy: -0.004).contains(centre)
                    || item.box.contains(CGPoint(x: existing.box.midX, y: existing.box.midY))
            }
            if !duplicate { found.append(item) }
        }
    }

    /// Horizontal strips worth a second look, in normalised page space.
    private static func bands(chords: [Found], lyricLines: [CGRect]) -> [CGRect] {
        var strips: [CGRect] = []
        for chord in chords {
            let h = chord.box.height
            strips.append(CGRect(x: 0, y: chord.box.minY - h * 0.8,
                                 width: 1, height: h * 2.6))
        }
        for line in lyricLines {
            let h = line.height
            strips.append(CGRect(x: 0, y: line.minY - h * 1.7,
                                 width: 1, height: h * 1.9))
        }
        // Merge overlapping strips so one chord line is read once.
        let sorted = strips
            .map { $0.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            .filter { !$0.isNull && $0.height > 0 }
            .sorted { $0.minY < $1.minY }
        var merged: [CGRect] = []
        for strip in sorted {
            if let last = merged.last, strip.minY < last.maxY - last.height * 0.3 {
                merged[merged.count - 1] = last.union(strip)
            } else {
                merged.append(strip)
            }
        }
        return merged
    }

    /// Ranges of the space-separated words in a line.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == " " {
                if let s = start { out.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let s = start { out.append(s..<text.endIndex) }
        return out
    }

    /// The fallback when Vision has no box for a range: the word's share of
    /// the line by character count.
    private static func estimatedBox(of range: Range<String.Index>,
                                     in text: String,
                                     line: CGRect) -> CGRect {
        let total = CGFloat(max(text.count, 1))
        let from = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound)) / total
        let width = CGFloat(text.distance(from: range.lowerBound, to: range.upperBound)) / total
        return CGRect(x: line.minX + line.width * from, y: line.minY,
                      width: line.width * width, height: line.height)
    }

    // MARK: - Key

    /// The semitones from the key a score is written in to the key the team
    /// plays it in, or nil when either cannot be told.
    ///
    /// The score's key is estimated as its most common chord root, which
    /// is right for the ordinary worship song and wrong for one that lives
    /// on its IV chord — so the result is shown as a starting point the
    /// reader can see and change, never applied silently.
    ///
    /// The shift is kept within −5…+6: G to F is −2, not +10, because a
    /// chart moved ten steps up reads the same and a person thinks of it as
    /// two down.
    static func shift(fromScoreChords symbols: [String], toKey teamKey: String?) -> Int? {
        guard let teamKey, let target = keyRoot(teamKey),
              let source = ScoreChordText.likelyRoot(of: symbols) else { return nil }
        var shift = ((target - source) % 12 + 12) % 12
        if shift > 6 { shift -= 12 }
        return shift
    }

    /// The root of a key as a leader types it — "A", "Bb", "F#m", "E major",
    /// "D키" — or nil.
    static func keyRoot(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "키", with: "")
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        guard let first = cleaned.split(separator: " ").first else { return nil }
        var token = String(first)
        // "F#m" names a minor key, whose chords are spelled from F#.
        if token.count > 1, token.hasSuffix("m") { token.removeLast() }
        return ScoreChordText.parse(token).flatMap { $0.suffix.isEmpty ? $0.root : nil }
    }
}
