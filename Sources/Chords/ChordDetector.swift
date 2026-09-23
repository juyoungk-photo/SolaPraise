//
//  ChordDetector.swift
//  PraiseTheLord
//
//  Matches a 12-bin chroma vector against chord templates and returns the
//  best-fit chord. Uses cosine similarity + hysteresis so the output does
//  not flicker between frames.
//
//  v1 templates: 12 major + 12 minor triads.
//  v1.5 templates (already wired but disabled below): maj7, m7, 7.
//

import Foundation

final class ChordDetector {

    // MARK: - Templates

    /// (intervals-in-semitones, quality) tuples used to build templates.
    private static let qualitySpecs: [(String, [Int], ChordQuality)] = [
        ("maj",  [0, 4, 7],    .major),
        ("min",  [0, 3, 7],    .minor),
        // Enable these by flipping the `if true` below in `buildTemplates()`.
        ("7",    [0, 4, 7, 10], .dominant7),
        ("maj7", [0, 4, 7, 11], .major7),
        ("m7",   [0, 3, 7, 10], .minor7),
        // Suspended and add9 shapes. NOTE: sus2 and sus4 are inversions of one
        // another in pitch-class terms (Csus2 = C,D,G; Gsus4 = G,C,D), so the
        // chroma alone cannot separate them — the bass note decides, which is
        // why BassDetector is now wired into the pipeline.
        ("sus2", [0, 2, 7],    .sus2),
        ("sus4", [0, 5, 7],    .sus4),
        ("add9", [0, 2, 4, 7], .add9),

        // ── Tensions ──────────────────────────────────────────────
        // AMBIGUITY WARNING: several of these are identical in pitch-class
        // space and cannot be told apart from chroma alone —
        //   C6  = C E G A  ==  Am7 = A C E G
        //   Cadd9 = C D E G ==  Gsus4/… depending on voicing
        // Only the bass note separates them, which is why BassDetector feeds
        // into DetectionSession. Where the bass is unclear the detector will
        // pick whichever template wins, and the lead sheet stays editable.
        ("maj9",  [0, 2, 4, 7, 11], .major9),
        ("m9",    [0, 2, 3, 7, 10], .minor9),
        ("9",     [0, 2, 4, 7, 10], .dominant9),
        ("7sus4", [0, 5, 7, 10],    .dominant7sus4),
        ("6",     [0, 4, 7, 9],     .sixth),
        ("m6",    [0, 3, 7, 9],     .minor6),
        ("dim",   [0, 3, 6],        .diminished),
        ("aug",   [0, 4, 8],        .augmented),
    ]

    /// Precomputed (chord, template) pairs.
    private let templates: [(chord: Chord, vec: [Float])]

    // MARK: - Hysteresis state

    private var lastReported: Chord?
    private var pendingChord: Chord?
    private var pendingCount: Int = 0
    /// Min consecutive frames a new chord must win before we switch.
    private let switchThreshold: Int = 2
    /// Reject matches with cosine similarity below this.
    private let minConfidence: Float = 0.60

    // MARK: - Init

    /// Defaults to ON. PraiseTheLord defaulted this off, so it only ever
    /// detected plain triads — unusable for worship, where maj7/m7/sus4 carry
    /// most of the harmonic colour.
    init(includeSevenths: Bool = true) {
        self.templates = ChordDetector.buildTemplates(includeSevenths: includeSevenths)
    }

    private static func buildTemplates(includeSevenths: Bool) -> [(Chord, [Float])] {
        var out: [(Chord, [Float])] = []

        for (_, intervals, quality) in qualitySpecs {
            let isExtended = intervals.count >= 4
            if isExtended && !includeSevenths { continue }

            for root in 0..<12 {
                var v = [Float](repeating: 0, count: 12)
                for interval in intervals {
                    v[(root + interval) % 12] = 1
                }
                // L2-normalize once up front so matching is just a dot product.
                var norm: Float = 0
                for x in v { norm += x * x }
                let inv = norm > 0 ? 1 / sqrtf(norm) : 0
                for i in 0..<12 { v[i] *= inv }

                out.append((Chord(root: root, quality: quality), v))
            }
        }
        return out
    }

    // MARK: - Detection

    /// Result of a detection attempt.
    struct Result {
        let chord: Chord
        let confidence: Float      // cosine similarity with the winning template
        let didChange: Bool        // true if this is a different chord from the previous stable one
    }

    /// The chords this detector can emit, in template order — the state space
    /// ChordHMM needs at construction.
    var chordSpace: [Chord] { templates.map(\.chord) }

    /// Cosine similarity against every template, in `chordSpace` order.
    /// Exposed so ChordHMM can smooth over the full distribution rather than
    /// just the arg-max this class reports.
    func similarities(from chroma: [Float]) -> [Float] {
        guard chroma.count == 12 else { return [] }
        return templates.map { t in
            var s: Float = 0
            for i in 0..<12 { s += chroma[i] * t.vec[i] }
            return s
        }
    }

    /// Feed a chroma vector; returns a Result only when we have a confident,
    /// stable match. Returns nil otherwise (quiet, ambiguous, or no change
    /// and caller asked us to skip repeats).
    func detect(from chroma: [Float]) -> Result? {
        guard chroma.count == 12 else { return nil }

        // Cosine similarity == dot product (both vectors L2-normalized).
        var bestScore: Float = -1
        var bestChord: Chord?
        for t in templates {
            var s: Float = 0
            for i in 0..<12 { s += chroma[i] * t.vec[i] }
            if s > bestScore {
                bestScore = s
                bestChord = t.chord
            }
        }

        guard let candidate = bestChord, bestScore >= minConfidence else {
            // Too ambiguous — don't update.
            return nil
        }

        // Hysteresis so we don't flap between two near-equal chords.
        if candidate == pendingChord {
            pendingCount += 1
        } else {
            pendingChord = candidate
            pendingCount = 1
        }

        let isStable = pendingCount >= switchThreshold
        guard isStable else { return nil }

        let didChange = (candidate != lastReported)
        lastReported = candidate

        return Result(chord: candidate, confidence: bestScore, didChange: didChange)
    }

    /// Reset internal state (call when starting a new session).
    func reset() {
        lastReported = nil
        pendingChord = nil
        pendingCount = 0
    }
}
