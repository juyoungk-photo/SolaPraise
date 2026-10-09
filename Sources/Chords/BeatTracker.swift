//
//  BeatTracker.swift
//  SolaPraise
//
//  Where the beats are, and which one starts the bar.
//
//  WHY A CHART NEEDS THIS: the detector reports a chord whenever its guess
//  changes, which is a moment decided by the analysis rather than by the
//  music. So a chart said "G at 0:47.3" — a time that corresponds to nothing
//  a musician can find. You cannot count yourself in to 0:47.3.
//
//  A chord belongs to a bar. Finding the bar line and putting the chord
//  there costs a little delay and makes the result readable: four chords to
//  a line, each where you would actually play it.
//
//  HOW: onset strength (spectral flux) → tempo by autocorrelation → beat
//  phase by scoring pulse trains → downbeat by picking the accented beat of
//  each four. Deliberately plain. Worship music is overwhelmingly 4/4 at a
//  steady tempo with a drummer or a strummed guitar marking it, which is the
//  easy case for this family of methods; the hard cases this would fail on —
//  rubato, metric modulation — are not what a Sunday set is made of.
//
//  Everything here is a pure function over a flux series, so it can be
//  checked without audio. See Tools/check-beat-tracker.swift.
//

import Foundation

/// A steady pulse found in a recording.
struct Rhythm: Equatable {
    let bpm: Double
    /// Every beat, in seconds from the start of the analysed audio.
    let beats: [TimeInterval]
    /// The first beat of each bar — the subset of `beats` a chord lands on.
    let downbeats: [TimeInterval]
    let beatsPerBar: Int
    /// How much the tempo peak stood out from the rest, 0…1. Low means the
    /// recording had no clear pulse and the bars below are a guess.
    let confidence: Double

    var secondsPerBeat: TimeInterval { 60 / bpm }
    var secondsPerBar: TimeInterval { secondsPerBeat * Double(beatsPerBar) }
}

enum BeatTracker {

    /// Worship sits comfortably inside this. Below 60 the autocorrelation
    /// starts locking onto half-time, above 180 onto the subdivision.
    static let bpmRange: ClosedRange<Double> = 60...180

    /// Finds the pulse in an onset-strength series.
    ///
    /// - Parameters:
    ///   - flux: onset strength per hop, one value per analysis frame.
    ///   - hopSeconds: seconds between consecutive flux values.
    static func track(flux: [Float],
                      hopSeconds: Double,
                      beatsPerBar: Int = 4) -> Rhythm? {
        guard hopSeconds > 0, flux.count > 32 else { return nil }

        let signal = normalise(flux)
        guard signal.contains(where: { $0 > 0 }) else { return nil }

        guard let (period, confidence) = tempo(of: signal, hopSeconds: hopSeconds)
        else { return nil }

        let beatHops = Double(period)
        let phase = bestPhase(signal, period: beatHops)

        var beats: [TimeInterval] = []
        var position = Double(phase)
        while position < Double(signal.count) {
            beats.append(position * hopSeconds)
            position += beatHops
        }
        guard beats.count >= beatsPerBar else { return nil }

        let first = downbeatOffset(signal, beats: beats,
                                   hopSeconds: hopSeconds, beatsPerBar: beatsPerBar)
        let downbeats = stride(from: first, to: beats.count, by: beatsPerBar)
            .map { beats[$0] }

        return Rhythm(bpm: 60 / (beatHops * hopSeconds),
                      beats: beats,
                      downbeats: downbeats,
                      beatsPerBar: beatsPerBar,
                      confidence: confidence)
    }

    // MARK: - Preparing the signal

    /// Mean-removed and half-wave rectified: autocorrelation wants the
    /// RISES in onset strength, and a constant floor correlates with
    /// everything equally and tells you nothing.
    private static func normalise(_ flux: [Float]) -> [Double] {
        let values = flux.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let centred = values.map { max(0, $0 - mean) }
        let peak = centred.max() ?? 0
        guard peak > 0 else { return centred }
        return centred.map { $0 / peak }
    }

    // MARK: - Tempo

    /// Autocorrelation peak inside the plausible range.
    ///
    /// Returns the lag in hops and how far the peak stood above the median
    /// of the candidates, which is the useful confidence: a recording with
    /// no pulse produces a flat curve with no winner, and saying so is
    /// better than reporting whichever bin happened to be highest.
    private static func tempo(of signal: [Double],
                              hopSeconds: Double) -> (period: Double, confidence: Double)? {
        let minLag = max(2, Int((60 / bpmRange.upperBound) / hopSeconds))
        let maxLag = min(signal.count / 2, Int((60 / bpmRange.lowerBound) / hopSeconds))
        guard maxLag > minLag else { return nil }

        // Autocorrelation on its own CANNOT pick the beat, and getting
        // this right took three attempts.
        //
        // A periodic pulse correlates with itself at every multiple of its
        // period, so a song at 120 peaks just as hard at 60, 40 and 30. Any
        // rule of the form "prefer the slower one" fires every time and
        // halves the whole library; "prefer the faster one" locks onto the
        // subdivision. The ambiguity is real in the signal, and three things
        // are needed to resolve it:
        //
        // 1. FRACTIONAL periods. This was the one that mattered. At a 23ms
        //    hop, 140 BPM is 18.43 hops — between bins — while its double is
        //    very nearly the exact integer 37. Sampling only integer lags
        //    therefore measured the fundamental at a depressed, off-peak
        //    value and its harmonic at full height, and 140 came back as 70
        //    no matter what weighting sat on top. Scanning in fractions of a
        //    hop depresses a period and its harmonics equally, so the bias
        //    cancels and the comparison becomes fair.
        // 2. A COMB over harmonics. A true period has support at p, 2p and
        //    3p; a spurious 2p has support at 2p and 4p but nothing at p.
        // 3. A PRIOR over how fast music is. Tempo perception clusters near
        //    two beats a second and falls off symmetrically in OCTAVES, so a
        //    log-normal centred on 120 breaks what the comb leaves.
        let centreBPM = 120.0
        let octaveWidth = 0.9

        // Correlation out to four times the slowest candidate, so the comb
        // has harmonics to look at.
        let acfLimit = min(signal.count - 2, maxLag * 4)
        guard acfLimit > minLag else { return nil }
        var acf = [Double](repeating: 0, count: acfLimit + 1)
        for lag in 1...acfLimit {
            var sum = 0.0
            for i in 0..<(signal.count - lag) { sum += signal[i] * signal[i + lag] }
            acf[lag] = sum / Double(signal.count - lag)
        }

        /// The correlation at a fractional lag.
        ///
        /// Quadratic through the three nearest samples rather than linear:
        /// an autocorrelation peak is curved, and a straight line between
        /// two samples either side of it reads well below the true value —
        /// which is the very bias this is here to remove.
        func acfAt(_ x: Double) -> Double {
            guard x >= 1, x <= Double(acfLimit) else { return 0 }
            let i = Int(x.rounded())
            guard i >= 1, i <= acfLimit else { return 0 }
            guard i > 1, i < acfLimit else { return acf[i] }
            let d = x - Double(i)
            let a = acf[i - 1], b = acf[i], c = acf[i + 1]
            return b + 0.5 * d * (c - a) + 0.5 * d * d * (a - 2 * b + c)
        }

        func comb(_ period: Double) -> Double {
            var total = 0.0
            for harmonic in 1...4 {
                let at = period * Double(harmonic)
                guard at <= Double(acfLimit) else { break }
                total += acfAt(at) / Double(harmonic)
            }
            return total
        }

        // A twentieth of a hop is about one millisecond — far finer than the
        // tracker needs, and the whole scan is a few thousand operations.
        let step = 0.05
        var period = Double(minLag)
        var best = -1.0
        var candidate = Double(minLag)
        while candidate <= Double(maxLag) {
            let bpm = 60 / (candidate * hopSeconds)
            let octaves = log2(bpm / centreBPM) / octaveWidth
            let score = comb(candidate) * exp(-0.5 * octaves * octaves)
            if score > best { best = score; period = candidate }
            candidate += step
        }
        guard best > 0 else { return nil }

        // Confidence from the plain correlation: the comb and the prior are
        // there to choose between harmonics, not to make a flat curve look
        // convincing.
        let candidates = (minLag...maxLag).map { acf[$0] }.sorted()
        let median = candidates[candidates.count / 2]
        let confidence = median > 0
            ? min(1, max(0, (acfAt(period) / median - 1) / 2))
            : 1

        return (period, confidence)
    }

    // MARK: - Phase

    /// Which offset makes the pulse train land on the onsets.
    private static func bestPhase(_ signal: [Double], period: Double) -> Int {
        var bestOffset = 0
        var best = -1.0
        for offset in 0..<Int(period.rounded()) {
            var sum = 0.0
            var position = Double(offset)
            while position < Double(signal.count) {
                sum += energy(signal, around: Int(position.rounded()))
                position += period
            }
            if sum > best { best = sum; bestOffset = offset }
        }
        return bestOffset
    }

    /// A beat the tracker places a hop early or late is still that beat, so
    /// scoring looks at a small window rather than one sample.
    private static func energy(_ signal: [Double], around index: Int) -> Double {
        var sum = 0.0
        for i in (index - 1)...(index + 1) where i >= 0 && i < signal.count {
            sum += signal[i]
        }
        return sum
    }

    // MARK: - Downbeat

    /// Which beat of the four starts the bar.
    ///
    /// Picked by accent: in worship the kick and the chord change land on
    /// one, so of the four candidate phases the one whose beats carry the
    /// most onset energy is the bar line. It is a guess, and a wrong one
    /// shifts every chord by a beat rather than scrambling the chart — which
    /// is why it is worth making rather than defaulting to zero.
    private static func downbeatOffset(_ signal: [Double],
                                       beats: [TimeInterval],
                                       hopSeconds: Double,
                                       beatsPerBar: Int) -> Int {
        var best = 0
        var bestScore = -1.0
        for offset in 0..<beatsPerBar {
            var sum = 0.0
            for index in stride(from: offset, to: beats.count, by: beatsPerBar) {
                let hop = Int((beats[index] / hopSeconds).rounded())
                sum += energy(signal, around: hop)
            }
            let count = max(1, (beats.count - offset + beatsPerBar - 1) / beatsPerBar)
            let mean = sum / Double(count)
            if mean > bestScore { bestScore = mean; best = offset }
        }
        return best
    }
}
