//
//  KeyEstimator.swift
//  PraiseTheLord
//
//  Krumhansl-Schmuckler key-finding algorithm.
//  Accumulate chroma vectors across the session, then correlate the running
//  total against 24 key profiles (12 major + 12 minor). Best fit is the key.
//

import Foundation

final class KeyEstimator {

    // Krumhansl-Kessler major/minor profiles (empirical).
    private static let majorProfile: [Float] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
        2.52, 5.19, 2.39, 3.66, 2.29, 2.88
    ]
    private static let minorProfile: [Float] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
        2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]

    private var cumulative: [Float] = Array(repeating: 0, count: 12)

    func add(chroma: [Float]) {
        guard chroma.count == 12 else { return }
        for i in 0..<12 { cumulative[i] += chroma[i] }
    }

    func reset() {
        cumulative = Array(repeating: 0, count: 12)
    }

    /// Returns ("G", .major) style result, or nil if not enough data yet.
    func estimate() -> (rootName: String, isMajor: Bool, score: Float)? {
        // Need some accumulated energy.
        let sum = cumulative.reduce(0, +)
        guard sum > 1 else { return nil }

        var bestScore: Float = -.greatestFiniteMagnitude
        var bestRoot = 0
        var bestMajor = true

        for root in 0..<12 {
            let rotatedMajor = rotated(Self.majorProfile, by: root)
            let rotatedMinor = rotated(Self.minorProfile, by: root)

            let sMaj = correlate(cumulative, rotatedMajor)
            let sMin = correlate(cumulative, rotatedMinor)

            if sMaj > bestScore { bestScore = sMaj; bestRoot = root; bestMajor = true }
            if sMin > bestScore { bestScore = sMin; bestRoot = root; bestMajor = false }
        }

        return (Chord.sharpNames[bestRoot], bestMajor, bestScore)
    }

    /// Nice display string, e.g. "G major" / "E minor".
    func displayString() -> String? {
        guard let e = estimate() else { return nil }
        return "\(e.rootName) \(e.isMajor ? "major" : "minor")"
    }

    // MARK: - Helpers

    private func rotated(_ v: [Float], by k: Int) -> [Float] {
        let n = v.count
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[(i + k) % n] = v[i] }
        return out
    }

    /// Pearson correlation without centering (both vectors non-negative):
    /// dot(a,b) / (|a| * |b|). Equivalent to cosine similarity.
    private func correlate(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = sqrtf(na) * sqrtf(nb)
        return denom > 0 ? dot / denom : 0
    }
}
