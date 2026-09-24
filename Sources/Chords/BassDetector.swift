//
//  BassDetector.swift
//  PraiseTheLord — v1.5 upgrade
//
//  Detects the current bass pitch class by analyzing only low-frequency
//  content (~40–250 Hz, i.e. guitar/bass E2..B3 roughly).
//
//  Why: praise songs use a lot of inversions and slash chords
//  ("C – G/B – Am – F", "D – Dsus4 – A/C# – Bm"). The bass note tells
//  the chord matcher whether G with a B in the bass is a C/G voicing,
//  a G6, or a G with chromatic passing — a regular chroma can't tell.
//
//  How to wire up:
//    In DetectionSession:
//        private let bass = BassDetector()
//        ...
//        let bassPC = bass.process(buffer: buffer)    // Int? in 0..11
//    Pass bassPC into the chord matcher; it can penalize templates whose
//    root does not match the bass (unless it's a legitimate 1st/2nd-inv).
//

import Accelerate
import AVFoundation

final class BassDetector {

    // MARK: - Parameters
    /// 32768, not 8192.
    ///
    /// An 8192-point FFT gives 5.4 Hz bins at 44.1 kHz. A semitone at E1
    /// (41 Hz) spans 2.4 Hz, so a single bin covered more than two semitones
    /// in exactly the band this class exists to read — the detector could not
    /// resolve pitch at all down there, and which semitone a peak landed on
    /// depended on where the bin grid happened to fall. That is why the same
    /// notes read as D at 44.1 kHz and A at 48 kHz.
    ///
    /// 32768 brings bins to 1.35 Hz, and the parabolic interpolation below
    /// takes the estimate well inside a semitone from there. The window is
    /// 0.68 s, which is fine: a bass note holds for a chord, not a frame.
    private let fftSize: Int = 32768
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let sampleRate: Double

    /// Frequency range we consider "bass".
    /// 41 Hz ≈ E1 (5-string bass low B is 31 Hz — raise if you need it).
    /// 260 Hz ≈ C4 (middle C).
    private let minHz: Double = 41.0
    private let maxHz: Double = 260.0

    // MARK: - Buffers
    private var ring: [Float]
    private var ringWrite: Int = 0
    private var hann: [Float]
    private var realp: [Float]
    private var imagp: [Float]

    // Smoothed per-pitch-class strength in the bass band.
    private var smoothed: [Float] = Array(repeating: 0, count: 12)
    private let smoothingAlpha: Float = 0.8

    // MARK: - Init
    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("BassDetector: FFT setup failed")
        }
        self.fftSetup = setup
        self.ring = Array(repeating: 0, count: fftSize)
        self.realp = Array(repeating: 0, count: fftSize / 2)
        self.imagp = Array(repeating: 0, count: fftSize / 2)

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.hann = window
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - Public

    /// Result of a bass detection pass.
    struct Result {
        let pitchClass: Int           // 0..11
        let strength: Float           // 0..1 confidence
        let strongestMidi: Int        // MIDI note number of the dominant bass bin
    }

    /// Feed PCM; returns the most likely bass pitch class (or nil if
    /// the band is too quiet to be trustworthy).
    func process(buffer: AVAudioPCMBuffer) -> Result? {
        guard let ch = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        for i in 0..<n {
            ring[ringWrite] = ch[i]
            ringWrite = (ringWrite + 1) % fftSize
        }
        return analyze()
    }

    // MARK: - Internal

    private func analyze() -> Result? {
        // 1) Window the ring buffer.
        var windowed = [Float](repeating: 0, count: fftSize)
        let head = ringWrite
        for i in 0..<fftSize {
            windowed[i] = ring[(head + i) % fftSize]
        }
        vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        // 2) FFT magnitude.
        var mags = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { rPtr in
            imagp.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!,
                                            imagp: iPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { wPtr in
                    wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                        capacity: fftSize / 2) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
                var c = Int32(fftSize / 2)
                vvsqrtf(&mags, mags, &c)
            }
        }

        // 3) Only sum energy in the bass band, folded into 12 pitch classes.
        let binHz = sampleRate / Double(fftSize)
        let minBin = max(1, Int(minHz / binHz))
        let maxBin = min(fftSize / 2 - 1, Int(maxHz / binHz))

        var pcEnergy = [Float](repeating: 0, count: 12)
        var bandTotal: Float = 0
        var bestMag: Float = 0
        var bestMidi: Int = 48    // C3 fallback

        // Peaks only, not every bin.
        //
        // Summing all bins spread one note's energy across its neighbours and
        // therefore across pitch classes, so a strong note leaked into the
        // semitones either side of it. A partial is a local maximum; the bins
        // around it are the window's skirt, not other notes.
        for k in max(minBin, 1) ... min(maxBin, fftSize / 2 - 2) {
            let m = mags[k]
            guard m > 0, m >= mags[k - 1], m > mags[k + 1] else { continue }

            // Parabolic interpolation over the peak and its two neighbours
            // recovers the true frequency to a fraction of a bin, which is
            // what makes semitone resolution possible this low down.
            let alpha = Double(mags[k - 1])
            let beta = Double(m)
            let gamma = Double(mags[k + 1])
            let denominator = alpha - 2 * beta + gamma
            let offset = denominator == 0 ? 0 : 0.5 * (alpha - gamma) / denominator
            let f = (Double(k) + offset) * binHz
            guard f >= minHz, f <= maxHz else { continue }

            // MIDI note number; 69 = A4, 440 Hz.
            let midiF = 69.0 + 12.0 * log2(f / 440.0)
            let midi = Int(midiF.rounded())
            let pc = ((midi % 12) + 12) % 12

            // Weighted toward the bottom of the band: the bass note is the
            // lowest one, and a loud partial an octave up is not it.
            let weight = Float(maxHz / max(f, minHz))
            pcEnergy[pc] += m * weight
            bandTotal += m * weight
            if m > bestMag {
                bestMag = m
                bestMidi = midi
            }
        }
        guard bandTotal > 1e-4 else { return nil }

        // 4) Smooth across frames so the bass label doesn't flicker with
        //    eighth-note passing tones.
        for i in 0..<12 {
            smoothed[i] = smoothingAlpha * smoothed[i] + (1 - smoothingAlpha) * pcEnergy[i]
        }

        // 5) Pick the dominant smoothed pitch class.
        var bestPC = 0
        var bestEnergy: Float = -1
        var total: Float = 0
        for i in 0..<12 {
            total += smoothed[i]
            if smoothed[i] > bestEnergy {
                bestEnergy = smoothed[i]
                bestPC = i
            }
        }

        let strength = total > 0 ? bestEnergy / total : 0
        // Require the winner to be meaningfully stronger than average.
        guard strength > 0.18 else { return nil }

        return Result(pitchClass: bestPC, strength: strength, strongestMidi: bestMidi)
    }
}
