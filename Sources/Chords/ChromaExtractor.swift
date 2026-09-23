//
//  ChromaExtractor.swift
//  PraiseTheLord
//
//  Turns raw PCM audio into a 12-bin chroma (pitch-class profile) vector
//  using Apple's Accelerate / vDSP FFT. Completely on-device.
//
//  Pipeline per frame:
//     raw samples  ->  accumulate in 4096 ring  ->  Hann window  ->
//     forward real FFT  ->  magnitude spectrum  ->
//     fold each bin into its pitch class (mod 12)  ->  L2-normalize  ->
//     exponential moving average across frames.
//

import Accelerate
import AVFoundation

final class ChromaExtractor {

    // MARK: - Parameters
    private let fftSize: Int = 4096
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let sampleRate: Double

    /// Consider only frequencies between these in Hz.
    /// Below ~60 Hz is rumble, above ~5 kHz is mostly overtones that confuse
    /// the chroma folding.
    private let minFreq: Double = 60.0
    private let maxFreq: Double = 5000.0

    // MARK: - Buffers
    private var ring: [Float]                       // circular buffer of samples
    private var ringWrite: Int = 0
    private var hann: [Float]                       // pre-computed Hann window

    // Scratch space for FFT (split complex form required by vDSP).
    private var realp: [Float]
    private var imagp: [Float]

    // MARK: - Smoothing
    private var smoothed: [Float] = Array(repeating: 0, count: 12)
    /// 0 = no smoothing, 1 = never update. We use 0.85 -> ~1 s decay at
    /// ~43 updates per second (44100 / 1024).
    private var smoothingAlpha: Float = 0.85

    // MARK: - Init

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Could not create FFT setup")
        }
        self.fftSetup = setup

        self.ring = Array(repeating: 0, count: fftSize)
        self.realp = Array(repeating: 0, count: fftSize / 2)
        self.imagp = Array(repeating: 0, count: fftSize / 2)

        // Hann window: 0.5 * (1 - cos(2*pi*n/(N-1)))
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.hann = window
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Public API

    /// Feed a block of mono audio. Once the ring buffer is full enough, this
    /// computes a new chroma vector. Returns nil if we don't have a full
    /// window yet (rare; almost always returns a value).
    func process(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)

        // Write into the circular buffer.
        for i in 0..<n {
            ring[ringWrite] = ch[i]
            ringWrite = (ringWrite + 1) % fftSize
        }

        return computeChroma()
    }

    /// The most recently smoothed chroma vector (length 12). Useful for UIs
    /// that poll rather than using a callback.
    var current: [Float] { smoothed }

    // MARK: - Internal

    private func computeChroma() -> [Float] {
        // 1) Copy the ring buffer into a contiguous array starting at oldest.
        var windowed = [Float](repeating: 0, count: fftSize)
        let head = ringWrite
        for i in 0..<fftSize {
            windowed[i] = ring[(head + i) % fftSize]
        }

        // 2) Apply Hann window to reduce spectral leakage.
        vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        // 3) Pack real samples into split complex form. vDSP wants even
        //    samples in realp[], odd samples in imagp[].
        var chroma = [Float](repeating: 0, count: 12)
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

                // 4) Forward FFT.
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // 5) Magnitudes: |X[k]|^2, then sqrt.
                var mags = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
                var count = Int32(fftSize / 2)
                vvsqrtf(&mags, mags, &count)

                // 6) Fold each bin into a pitch class (0..11 == C..B).
                let binHz = sampleRate / Double(fftSize)
                let minBin = max(1, Int(minFreq / binHz))
                let maxBin = min(fftSize / 2 - 1, Int(maxFreq / binHz))

                for k in minBin...maxBin {
                    let f = Double(k) * binHz
                    // MIDI-note-relative pitch class: 69 = A4.
                    let midi = 69.0 + 12.0 * log2(f / 440.0)
                    let pc = Int(midi.rounded()) % 12
                    // Handle negative wrap (shouldn't happen in our range).
                    let idx = (pc + 12) % 12
                    chroma[idx] += mags[k]
                }
            }
        }

        // 7) L2 normalize so loudness doesn't bias the chord match.
        var norm: Float = 0
        vDSP_svesq(chroma, 1, &norm, 12)
        if norm > 0 {
            var inv = 1.0 / sqrtf(norm)
            vDSP_vsmul(chroma, 1, &inv, &chroma, 1, 12)
        }

        // 8) Exponential moving average for smoothing.
        for i in 0..<12 {
            smoothed[i] = smoothingAlpha * smoothed[i] + (1 - smoothingAlpha) * chroma[i]
        }

        return smoothed
    }
}
