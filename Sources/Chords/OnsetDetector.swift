//
//  OnsetDetector.swift
//  SolaPraise
//
//  How much the sound CHANGED since the last frame — the signal a beat
//  tracker needs.
//
//  Spectral flux: take the magnitude spectrum, keep only the bins that grew
//  since last time, and sum them. A struck piano chord, a kick, a strummed
//  guitar all show as a spike; a sustained pad does not, because nothing
//  grew. Half-wave rectification is the whole trick — without it a note
//  ending counts as much as a note starting, and the series tracks activity
//  rather than attacks.
//
//  Separate from the chroma extractor on purpose. Chroma folds the spectrum
//  into twelve pitch classes and smooths it over time, which is exactly
//  right for naming a chord and exactly wrong for locating an attack: both
//  operations destroy the sharp broadband transient this is looking for.
//  Running a second small FFT costs about forty frames a second, which is
//  nothing next to what the NNLS chroma is already doing.
//

import Foundation
import Accelerate
import AVFoundation

final class OnsetDetector {

    /// Short on purpose. The chroma extractor uses 4096 to resolve pitch;
    /// this wants time resolution instead, and 1024 frames is about 23ms —
    /// comfortably finer than the gap between two beats at any tempo.
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    private var ring: [Float]
    private var ringWrite = 0
    private var hann: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var previous: [Float]

    init?() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        fftSetup = setup
        ring = Array(repeating: 0, count: fftSize)
        realp = Array(repeating: 0, count: fftSize / 2)
        imagp = Array(repeating: 0, count: fftSize / 2)
        previous = Array(repeating: 0, count: fftSize / 2)

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hann = window
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// One onset-strength value for this buffer.
    func process(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            ring[ringWrite] = channel[i]
            ringWrite = (ringWrite + 1) % fftSize
        }
        return flux()
    }

    private func flux() -> Float {
        var windowed = [Float](repeating: 0, count: fftSize)
        let head = ringWrite
        for i in 0..<fftSize { windowed[i] = ring[(head + i) % fftSize] }
        vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { rPtr in
            imagp.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!,
                                            imagp: iPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { wPtr in
                    wPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: fftSize / 2
                    ) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        var count = Int32(fftSize / 2)
        vvsqrtf(&magnitudes, magnitudes, &count)

        // Compressed before differencing.
        //
        // A chord struck fortissimo and the same chord struck quietly are
        // the same event to a beat tracker, but their raw flux differs by an
        // order of magnitude — so a loud chorus would dominate the
        // autocorrelation and a quiet verse would contribute nothing.
        // log(1+x) puts them on comparable footing.
        for i in magnitudes.indices { magnitudes[i] = log1pf(magnitudes[i]) }

        var sum: Float = 0
        for i in magnitudes.indices {
            let rise = magnitudes[i] - previous[i]
            if rise > 0 { sum += rise }
        }
        previous = magnitudes
        return sum
    }
}
