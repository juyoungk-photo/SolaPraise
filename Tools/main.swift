//
//  main.swift — chord-detection harness
//  SolaPraise — developer tool, not part of the app target.
//
//  Runs the live-detection DSP over synthesized chords so a regression in
//  chroma, the detector or the HMM shows up without a device, a microphone
//  and a guess about what was played.
//
//  Build and run:
//      swift Tools/run-chord-harness.swift
//

import AVFoundation
import Foundation

let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

/// One second of a chord rendered as a plucked-string-ish tone: a few
/// harmonics per note, decaying, so the spectrum resembles an instrument
/// rather than a set of pure sines the extractor could match too easily.
func render(midiNotes: [Int], sampleRate: Double, seconds: Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate,
                               channels: 1,
                               interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let out = buffer.floatChannelData![0]

    for i in 0 ..< Int(frames) {
        let t = Double(i) / sampleRate
        var sample = 0.0
        for note in midiNotes {
            let f0 = 440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)
            for harmonic in 1 ... 6 {
                let amp = 0.5 / Double(harmonic * harmonic)
                sample += amp * sin(2 * .pi * f0 * Double(harmonic) * t)
            }
        }
        out[i] = Float(sample / Double(midiNotes.count) * 0.6)
    }
    return buffer
}

struct Case {
    let label: String
    let notes: [Int]      // MIDI
    let expectRoot: Int   // pitch class
    /// A second root that is equally correct from chroma alone.
    ///
    /// Chroma is a set of pitch classes with no notion of which note is at the
    /// bottom, and some chords are the same set: Dsus4 is D-G-A and Gsus2 is
    /// G-A-D. No chroma-only detector can separate them, and calling that a
    /// failure would be marking the maths wrong for being right. The bass
    /// check below is what actually resolves it.
    var alsoRoot: Int? = nil
}

// Root position, third octave upward — the register a guitar or piano
// actually voices these in.
let cases: [Case] = [
    Case(label: "C",     notes: [48, 52, 55], expectRoot: 0),
    Case(label: "Am",    notes: [45, 48, 52], expectRoot: 9),
    Case(label: "G",     notes: [43, 47, 50], expectRoot: 7),
    Case(label: "F",     notes: [41, 45, 48], expectRoot: 5),
    Case(label: "Dm",    notes: [50, 53, 57], expectRoot: 2),
    Case(label: "E",     notes: [40, 44, 47], expectRoot: 4),
    Case(label: "Cmaj7", notes: [48, 52, 55, 59], expectRoot: 0),
    Case(label: "G7",    notes: [43, 47, 50, 53], expectRoot: 7),
    Case(label: "Am7",   notes: [45, 48, 52, 55], expectRoot: 9),
    Case(label: "Dsus4", notes: [50, 55, 57], expectRoot: 2, alsoRoot: 7)
]

var failures = 0

for rate in [44_100.0, 48_000.0] {
    print("\n── \(Int(rate / 1000)) kHz ──────────────────────────────")
    for testCase in cases {
        let chroma = NNLSChromaExtractor(sampleRate: rate)
        let detector = ChordDetector(includeSevenths: true)
        let hmm = ChordHMM(chords: detector.chordSpace)

        let buffer = render(midiNotes: testCase.notes, sampleRate: rate, seconds: 2.0)

        // Feed it in engine-sized chunks, exactly as AudioEngine's tap does.
        let chunk = 1024
        let source = buffer.floatChannelData![0]
        let format = buffer.format
        var last: Chord?

        for offset in stride(from: 0, to: Int(buffer.frameLength) - chunk, by: chunk) {
            let piece = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(chunk))!
            piece.frameLength = AVAudioFrameCount(chunk)
            memcpy(piece.floatChannelData![0], source + offset, chunk * MemoryLayout<Float>.size)

            guard let pcp = chroma.process(buffer: piece) else { continue }
            let similarities = detector.similarities(from: pcp)
            guard !similarities.isEmpty else { continue }
            if let chord = hmm.step(similarities: similarities) { last = chord }
        }

        let got = last.map { names[$0.root] + $0.quality.rawValue } ?? "—"
        let ok = last?.root == testCase.expectRoot || last?.root == testCase.alsoRoot
        if !ok { failures += 1 }
        print("  \(ok ? "✓" : "✗")  \(testCase.label.padding(toLength: 7, withPad: " ", startingAt: 0)) → \(got)")
    }
}

// The bass is what tells Dsus4 from Gsus2, so check it does.
print("\n── bass ────────────────────────────────────")
for rate in [44_100.0, 48_000.0] {
    let bass = BassDetector(sampleRate: rate)
    // D2 under the triad — how a band actually voices it. The bare D3-G3-A3
    // cluster above has its lowest note at 147 Hz with every note at equal
    // amplitude, and D3's third harmonic lands on A4, so A carries as much
    // low-end energy as D does. That is a property of the synthetic voicing,
    // not of the detector: given a real bass note it should say D.
    let buffer = render(midiNotes: [38, 50, 55, 57], sampleRate: rate, seconds: 2.0)
    let source = buffer.floatChannelData![0]
    let chunk = 1024
    var strongest: BassDetector.Result?

    for offset in stride(from: 0, to: Int(buffer.frameLength) - chunk, by: chunk) {
        let piece = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                     frameCapacity: AVAudioFrameCount(chunk))!
        piece.frameLength = AVAudioFrameCount(chunk)
        memcpy(piece.floatChannelData![0], source + offset, chunk * MemoryLayout<Float>.size)
        if let result = bass.process(buffer: piece),
           result.strength > (strongest?.strength ?? 0) {
            strongest = result
        }
    }

    let got = strongest.map { "\(names[$0.pitchClass]) (\(String(format: "%.2f", $0.strength)))" } ?? "—"
    // D2 is the bass of that voicing, so D is the answer.
    let ok = strongest?.pitchClass == 2
    if !ok { failures += 1 }
    print("  \(ok ? "✓" : "✗")  D2+D-G-A @ \(Int(rate / 1000))kHz → bass \(got)")
}

print("\n\(failures == 0 ? "ALL CORRECT" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
