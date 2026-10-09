//
//  check-beat-tracker.swift
//  SolaPraise
//
//  Checks that the beat tracker finds the tempo a song is actually at.
//
//  WHY THIS EXISTS: autocorrelation cannot pick the beat on its own. A
//  periodic pulse correlates with itself at every multiple of its period, so
//  120 BPM peaks just as hard at 60, 40 and 30 — and a tracker that lands on
//  the wrong octave produces a chart in half bars or double bars that looks
//  entirely plausible until somebody tries to play from it.
//
//  Three attempts failed here before one worked, and every failure would
//  have passed a casual look at one tempo. The suite sweeps four precisely
//  because the octave error is tempo-dependent: at a 23ms hop, 140 BPM is
//  18.43 hops — between bins — while its double lands on very nearly the
//  exact integer 37, so integer-lag sampling measured the fundamental low
//  and its harmonic high and reported 70. 72 and 88 passed the entire time
//  this was broken.
//
//  Run:
//      swiftc -O -o /tmp/btcheck \
//          Sources/Chords/BeatTracker.swift Tools/check-beat-tracker.swift
//      /tmp/btcheck
//

import Foundation

@main
struct CheckBeatTracker {

    /// The analyser's real hop: 1024 frames at 44.1kHz, about 23ms.
    static let hop = 1024.0 / 44100.0

    /// An onset series for a song at `bpm`, every fourth beat accented,
    /// with noise and optional jitter — a drummer is not a click track.
    static func flux(bpm: Double,
                     seconds: Double,
                     jitter: Double = 0,
                     noise: Double = 0.1,
                     downbeatOffset: Int = 0) -> [Float] {
        let n = Int(seconds / hop)
        var out = [Float](repeating: 0, count: n)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n { out[i] = Float(Double.random(in: 0...noise, using: &rng)) }

        let beat = 60.0 / bpm
        var t = 0.0
        var index = 0
        while t < seconds {
            let wobble = jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) : 0
            let at = Int(((t + wobble) / hop).rounded())
            if at >= 0, at < n {
                let isDownbeat = (index - downbeatOffset) % 4 == 0
                out[at] += Float(isDownbeat ? 1.0 : 0.6)
            }
            t += beat
            index += 1
        }
        return out
    }

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    static func main() {
        // The octave error is tempo-dependent, so sweep.
        for bpm in [72.0, 88.0, 120.0, 140.0] {
            guard let r = BeatTracker.track(flux: flux(bpm: bpm, seconds: 60),
                                            hopSeconds: hop) else {
                check("\(Int(bpm)) BPM found", false, "no rhythm at all")
                continue
            }
            check("\(Int(bpm)) BPM within 2", abs(r.bpm - bpm) <= 2,
                  "got \(String(format: "%.1f", r.bpm))")
        }

        // A real drummer: pushed and dragged, over a noisier floor.
        if let r = BeatTracker.track(
            flux: flux(bpm: 96, seconds: 90, jitter: 0.02, noise: 0.35),
            hopSeconds: hop
        ) {
            check("96 BPM with jitter and noise", abs(r.bpm - 96) <= 3,
                  "got \(String(format: "%.1f", r.bpm))")
        } else {
            check("96 BPM with jitter and noise", false, "no rhythm")
        }

        // The bar must be found, not assumed to start at the first beat.
        if let r = BeatTracker.track(flux: flux(bpm: 120, seconds: 60, downbeatOffset: 2),
                                     hopSeconds: hop) {
            let beat = 0.5
            let first = r.downbeats.first ?? -1
            check("downbeat phase recovered",
                  abs(first - 2 * beat) < beat * 0.6
                  || abs(first.truncatingRemainder(dividingBy: beat * 4) - 2 * beat) < beat * 0.6,
                  "first downbeat at \(String(format: "%.2f", first))s")
            check("bars are four beats apart",
                  r.downbeats.count > 4
                  && abs((r.downbeats[1] - r.downbeats[0]) - beat * 4) < 0.08,
                  "gap \(String(format: "%.3f", r.downbeats[1] - r.downbeats[0]))s")
        } else {
            check("downbeat phase recovered", false, "no rhythm")
        }

        // Nothing to find must return nothing, not a confident wrong answer.
        var quiet = [Float](repeating: 0, count: 2000)
        check("silence yields no rhythm", BeatTracker.track(flux: quiet, hopSeconds: hop) == nil)

        for i in quiet.indices { quiet[i] = Float.random(in: 0...1) }
        let noiseOnly = BeatTracker.track(flux: quiet, hopSeconds: hop)
        check("pure noise is low confidence",
              noiseOnly == nil || noiseOnly!.confidence < 0.35,
              "confidence \(noiseOnly.map { String(format: "%.2f", $0.confidence) } ?? "nil")")

        print(failures == 0
              ? "\nall beat tracker checks passed"
              : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
