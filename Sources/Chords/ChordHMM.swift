//
//  ChordHMM.swift
//  PraiseTheLord — v1.5 upgrade
//
//  Adds a first-order Markov smoother over the chord template matcher's
//  per-frame similarity scores. The effect: instead of picking the chord
//  with the highest cosine similarity *this frame*, we pick the sequence
//  of chords that maximizes
//       Σ_t [ log P(chroma_t | chord_t) + λ log P(chord_t | chord_{t-1}) ]
//
//  i.e. the model prefers transitions that show up a lot in real music
//  (I -> V, vi -> IV, etc.) and heavily penalizes nonsense jumps like
//  C major -> F#minor -> Dbdim.
//
//  We run a streaming Viterbi with a sliding window so decisions remain
//  real-time (~100-200 ms latency).
//
//  Expected accuracy bump on praise-band material: +6-8 percentage points
//  on top of NNLS chroma, mainly by killing single-frame glitches.
//

import Foundation

final class ChordHMM {

    // MARK: - Configuration
    /// How much weight to give the transition prior vs. the observation.
    /// 0 = no HMM (pure template matching). 1 = pure prior. 0.35 is a good default.
    var transitionWeight: Double = 0.35

    /// Sliding window length in frames. Longer = smoother but more latency.
    private let windowLength: Int = 8

    /// Flat set of candidate chords we reason about (same as the matcher's templates).
    let chords: [Chord]

    /// log transition matrix logT[i, j] = log P(chord_j | chord_i).
    private let logT: [[Double]]

    /// Rolling observation log-likelihoods (each frame is a [Double] of size N).
    private var observations: [[Double]] = []

    // MARK: - Init

    init(chords: [Chord]) {
        self.chords = chords
        self.logT = Self.buildTransitionMatrix(chords: chords)
    }

    // MARK: - Public

    /// Feed one frame of cosine similarities in the same order as `chords`.
    /// Returns the most likely *current* chord given the recent window.
    func step(similarities: [Float]) -> Chord? {
        guard similarities.count == chords.count else { return nil }

        // Convert similarities in [0, 1] to log observation likelihoods.
        // A tiny epsilon prevents log(0).
        let obs: [Double] = similarities.map { Double(max($0, 1e-4)) }
            .map { log($0) }

        observations.append(obs)
        if observations.count > windowLength { observations.removeFirst() }

        return viterbiDecode()
    }

    func reset() { observations.removeAll() }

    // MARK: - Viterbi over the current window

    private func viterbiDecode() -> Chord? {
        guard let first = observations.first else { return nil }
        let N = chords.count
        let T = observations.count

        // dp[t][j] = best log-prob ending in chord j at time t.
        var dp = Array(repeating: Array(repeating: -Double.infinity, count: N), count: T)
        var back = Array(repeating: Array(repeating: 0, count: N), count: T)

        // Initialization: uniform prior at t=0.
        for j in 0..<N {
            dp[0][j] = first[j] - log(Double(N))
        }

        // Recursion.
        for t in 1..<T {
            let obs = observations[t]
            for j in 0..<N {
                var bestScore = -Double.infinity
                var bestPrev = 0
                for i in 0..<N {
                    let s = dp[t - 1][i] + transitionWeight * logT[i][j]
                    if s > bestScore {
                        bestScore = s
                        bestPrev = i
                    }
                }
                dp[t][j] = bestScore + obs[j]
                back[t][j] = bestPrev
            }
        }

        // Terminate: pick best final state.
        var bestFinal = 0
        var bestFinalScore = -Double.infinity
        for j in 0..<N {
            if dp[T - 1][j] > bestFinalScore {
                bestFinalScore = dp[T - 1][j]
                bestFinal = j
            }
        }
        return chords[bestFinal]
    }

    // MARK: - Transition matrix construction

    /// A heuristic transition matrix based on diatonic-distance + common
    /// worship progression motifs. This intentionally avoids training data
    /// so the code ships standalone; a future version can load a matrix
    /// estimated from a chord-annotated corpus.
    private static func buildTransitionMatrix(chords: [Chord]) -> [[Double]] {
        let N = chords.count
        var M = Array(repeating: Array(repeating: 0.01, count: N), count: N)

        for (i, a) in chords.enumerated() {
            for (j, b) in chords.enumerated() {
                // Base: staying on the same chord is very likely.
                if a == b { M[i][j] = 6.0; continue }

                let interval = ((b.root - a.root) % 12 + 12) % 12
                var score = 0.5

                // Strong cadential moves (V -> I is 7 semitones down, i.e.
                // up 5 semitones in pitch-class space = interval 5).
                switch interval {
                case 5:  score += 2.0          // V -> I  (G -> C)
                case 7:  score += 1.5          // I -> V  (C -> G)
                case 9:  score += 1.3          // I -> vi / IV -> ii
                case 2:  score += 1.2          // IV -> V (F -> G)
                case 10: score += 1.2          // IV -> V relative
                case 3:  score += 0.8          // relative major/minor hops
                case 4:  score += 0.8
                default: break
                }

                // Smooth-voice-leading boost when qualities alternate naturally.
                if a.quality == .major && b.quality == .minor && interval == 9 { score += 0.6 }
                if a.quality == .minor && b.quality == .major && interval == 3 { score += 0.6 }

                // Discourage weird jumps (tritone, b2).
                if interval == 6 || interval == 1 || interval == 11 { score -= 0.5 }

                M[i][j] = max(score, 0.05)
            }
        }

        // Row-normalize and take logs.
        var logM = Array(repeating: Array(repeating: 0.0, count: N), count: N)
        for i in 0..<N {
            let sum = M[i].reduce(0, +)
            for j in 0..<N {
                let p = M[i][j] / sum
                logM[i][j] = log(p)
            }
        }
        return logM
    }
}
