//
//  NNLSChromaExtractor.swift
//  PraiseTheLord — v1.5 upgrade
//
//  Harmonic-subtracted chroma using Non-Negative Least Squares (NNLS)
//  multiplicative updates against a harmonic-template dictionary.
//
//  Inspired by Mauch & Dixon, "Approximate Note Transcription for the
//  Improved Identification of Difficult Chords" (ISMIR 2010).
//
//  Why this is a big deal for worship songs:
//    A plain-FFT chroma confuses Gmaj7 with G (the B overtone of G3
//    bleeds into a G-major chroma). NNLS explains the spectrum as a
//    sum of note templates whose overtones are explicitly modeled, so
//    the solver *attributes* that B energy to the real B note rather
//    than smearing it into G.
//
//  How it fits in:
//    Swap in place of ChromaExtractor in DetectionSession.swift:
//        private let chroma = NNLSChromaExtractor()
//

import Accelerate
import AVFoundation

final class NNLSChromaExtractor {

    // MARK: - Parameters
    private let fftSize: Int = 8192          // bigger than v1 for better low-freq resolution
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let sampleRate: Double

    /// Note range we model. MIDI 36 = C2 (65 Hz) to MIDI 95 = B6 (~1975 Hz).
    /// 60 semitones = 5 octaves; fine for guitars / piano / worship band.
    /// Static so `init` can size buffers from them. As instance members these
    /// could not be read during initialisation — Swift forbids touching `self`
    /// before every stored property is set, which is why this file did not
    /// compile as written.
    private static let midiLow: Int = 36
    private static let midiHigh: Int = 95
    private static let noteCount: Int = NNLSChromaExtractor.midiHigh - NNLSChromaExtractor.midiLow + 1

    /// Harmonic dictionary. Row = spectral bin, Col = candidate note.
    /// E[k, n] = amplitude contributed to spectral bin k by unit activation
    /// of note n (sum over its partials with 1/h exponential decay).
    private var dictionary: [[Float]] = []    // [numBins][noteCount]
    private let partialCount: Int = 6          // fundamental + 5 overtones
    private let partialDecay: Float = 0.6      // a_h = decay^(h-1)

    // MARK: - Buffers
    private var ring: [Float]
    private var ringWrite: Int = 0
    private var hann: [Float]
    private var realp: [Float]
    private var imagp: [Float]

    // Running note activations (warm-start for the NNLS solver).
    private var activations: [Float]

    // Smoothing
    private var smoothed: [Float] = Array(repeating: 0, count: 12)
    private let smoothingAlpha: Float = 0.85

    // MARK: - Init

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("NNLSChromaExtractor: FFT setup failed")
        }
        self.fftSetup = setup
        self.ring = Array(repeating: 0, count: fftSize)
        self.realp = Array(repeating: 0, count: fftSize / 2)
        self.imagp = Array(repeating: 0, count: fftSize / 2)

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.hann = window

        self.activations = Array(repeating: 0.01, count: Self.noteCount)

        buildDictionary()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - Public

    /// Feed PCM audio. Returns the latest 12-bin smoothed chroma vector
    /// (or nil until the ring buffer has warmed up).
    func process(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        for i in 0..<n {
            ring[ringWrite] = ch[i]
            ringWrite = (ringWrite + 1) % fftSize
        }
        let spectrum = magnitudeSpectrum()
        solveNNLS(target: spectrum, iterations: 12)
        return poolToChroma()
    }

    var current: [Float] { smoothed }

    // MARK: - Dictionary construction

    private func buildDictionary() {
        let numBins = fftSize / 2
        let binHz = Float(sampleRate) / Float(fftSize)

        // Each column: harmonic template for one note.
        var dict = Array(repeating: Array(repeating: Float(0), count: Self.noteCount),
                         count: numBins)

        for n in 0..<Self.noteCount {
            let midi = Self.midiLow + n
            let f0 = 440.0 * pow(2.0, (Float(midi) - 69.0) / 12.0)

            for h in 1...partialCount {
                let f = f0 * Float(h)
                let k = Int((f / binHz).rounded())
                guard k > 0, k < numBins else { continue }
                // 3-bin Gaussian smear so a partial isn't lost between bins.
                let amp = pow(partialDecay, Float(h - 1))
                for d in -2...2 {
                    let kk = k + d
                    if kk > 0, kk < numBins {
                        let g = expf(-Float(d * d) / 1.5)
                        dict[kk][n] += amp * g
                    }
                }
            }

            // L2-normalize each column so the solver is well-conditioned.
            var norm: Float = 0
            for k in 0..<numBins { norm += dict[k][n] * dict[k][n] }
            if norm > 0 {
                let inv = 1.0 / sqrtf(norm)
                for k in 0..<numBins { dict[k][n] *= inv }
            }
        }
        self.dictionary = dict
    }

    // MARK: - FFT magnitude spectrum

    private func magnitudeSpectrum() -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        let head = ringWrite
        for i in 0..<fftSize {
            windowed[i] = ring[(head + i) % fftSize]
        }
        vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

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
                var count = Int32(fftSize / 2)
                vvsqrtf(&mags, mags, &count)
            }
        }
        return mags
    }

    // MARK: - NNLS via multiplicative updates
    //
    // We want to find activations x >= 0 minimizing || E x - s ||^2.
    // Multiplicative (Lee-Seung style) update for non-negative least squares:
    //     x_n <- x_n * (E^T s)_n / ((E^T E x)_n + eps)
    // This keeps x >= 0 automatically and converges monotonically.
    // ~10 iterations are plenty for real-time; we also warm-start from the
    // previous frame so later iterations refine quickly.

    private func solveNNLS(target s: [Float], iterations: Int) {
        let numBins = s.count
        let numNotes = Self.noteCount
        let eps: Float = 1e-9

        // Precompute E^T * s  (length noteCount)
        var Ets = [Float](repeating: 0, count: numNotes)
        for n in 0..<numNotes {
            var acc: Float = 0
            for k in 0..<numBins { acc += dictionary[k][n] * s[k] }
            Ets[n] = acc
        }

        for _ in 0..<iterations {
            // Ex  (length numBins)
            var Ex = [Float](repeating: 0, count: numBins)
            for k in 0..<numBins {
                var acc: Float = 0
                for n in 0..<numNotes { acc += dictionary[k][n] * activations[n] }
                Ex[k] = acc
            }
            // E^T (E x)
            for n in 0..<numNotes {
                var acc: Float = 0
                for k in 0..<numBins { acc += dictionary[k][n] * Ex[k] }
                activations[n] = activations[n] * Ets[n] / (acc + eps)
            }
        }
    }

    // MARK: - Pool note activations into 12-bin chroma

    private func poolToChroma() -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        for n in 0..<Self.noteCount {
            let midi = Self.midiLow + n
            let pc = ((midi % 12) + 12) % 12
            chroma[pc] += activations[n]
        }
        // L2-normalize.
        var norm: Float = 0
        vDSP_svesq(chroma, 1, &norm, 12)
        if norm > 0 {
            var inv = 1.0 / sqrtf(norm)
            vDSP_vsmul(chroma, 1, &inv, &chroma, 1, 12)
        }
        // Exponential moving average.
        for i in 0..<12 {
            smoothed[i] = smoothingAlpha * smoothed[i] + (1 - smoothingAlpha) * chroma[i]
        }
        return smoothed
    }
}
