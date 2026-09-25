//
//  DetectionSession.swift
//  SolaPraise
//
//  Wires the full detection pipeline:
//    AudioEngine → NNLSChromaExtractor → ChordDetector similarities
//                → ChordHMM (Viterbi smoothing) → UI
//    AudioEngine → BassDetector → slash-chord bass
//
//  Adapted from PraiseTheLord, where this class only ever used the basic
//  ChromaExtractor and the plain triad detector — NNLSChromaExtractor,
//  BassDetector and ChordHMM were written but never called, despite the
//  README describing them as the active pipeline. They are called now.
//
//  Audio arrives via the mic while the YouTube player plays through the
//  speaker, which is what keeps this clear of audio-extraction ToS concerns.
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class DetectionSession: ObservableObject {

    // MARK: - Collaborators

    let audio = AudioEngine()

    /// Built from the INPUT's real sample rate, not a guess.
    ///
    /// These used to be created with the 44,100 Hz default while AudioEngine
    /// taps at the hardware's native format — 48,000 Hz on modern iPhones and
    /// on most USB audio interfaces. The chroma maths then read every
    /// frequency at 0.919x its true value, roughly 1.47 semitones flat, which
    /// is not even a whole semitone, so notes fell between bins and smeared.
    /// Live detection could not have been correct.
    private var chroma: NNLSChromaExtractor?
    private var bass: BassDetector?
    private var configuredSampleRate: Double = 0

    private let detector = ChordDetector(includeSevenths: true)
    private let keyEstimator = KeyEstimator()
    private lazy var hmm = ChordHMM(chords: detector.chordSpace)

    // MARK: - Published state

    @Published var currentChord: Chord?
    @Published var confidence: Float = 0
    @Published var history: [DetectedChord] = []        // newest last
    @Published var detectedKey: String?
    @Published var isRecording = false
    /// Between the tap and the first buffer. Activating the audio session and
    /// starting the engine both block for long enough to be felt, so the UI
    /// says so and stays cancellable instead of appearing to hang.
    @Published var isStarting = false
    @Published var permissionDenied = false

    // MARK: - Session state

    /// Where a chord sits in the VIDEO, not in wall-clock time.
    ///
    /// Without this the lead sheet is only correct when detection starts at
    /// 0:00 and the song plays straight through. Start it halfway, pause,
    /// or seek, and every timestamp is off by the difference — which makes a
    /// chart that cannot be followed against the recording it came from.
    /// Returning nil means "not playing", and those frames are dropped rather
    /// than filed as chords heard during silence.
    var positionProvider: (() -> Double?)?

    /// False while capturing purely to disk.
    ///
    /// Read on the audio thread, so it is a plain Bool set before the engine
    /// starts rather than anything that needs synchronising mid-run.
    var analyzes = true

    @Published private(set) var recordingURL: URL?
    @Published var recordingError: String?
    private var pendingRecordingTitle: String?

    /// Set when the user taps again before the engine has finished starting.
    private var cancelRequested = false

    private var startTime: Date?
    private var keyUpdateTimer: Timer?
    private var lastReported: Chord?
    /// Bass is sampled continuously but only attached when it is both
    /// confident and genuinely different from the chord root.
    private var latestBass: BassDetector.Result?
    /// Raised from 0.45. A weak bass estimate is worse than none, because a
    /// wrong slash makes an otherwise correct chord read as nonsense.
    private let bassStrengthFloor: Float = 0.70

    init() {
        audio.onBuffer = { [weak self] buffer in
            // Audio thread: do the DSP here, then hop to main with results.
            guard let self else { return }

            // Rebuild the extractors if the route changed — plugging in a USB
            // interface mid-session can switch the hardware rate.
            let rate = buffer.format.sampleRate
            if rate > 0, rate != self.configuredSampleRate {
                self.configuredSampleRate = rate
                self.chroma = NNLSChromaExtractor(sampleRate: rate)
                self.bass = BassDetector(sampleRate: rate)
            }
            // Recording a forty-minute service does not need a chord
            // readout, and running the FFTs anyway costs battery for a
            // display nobody is watching.
            guard self.analyzes else { return }
            guard let chroma = self.chroma, let bass = self.bass else { return }

            let pcp = chroma.process(buffer: buffer)
            let bassResult = bass.process(buffer: buffer)
            guard let pcp else { return }

            Task { @MainActor in
                self.handle(chroma: pcp, bass: bassResult)
            }
        }
    }

    // MARK: - Controls

    func start() {
        guard !isStarting, !isRecording else { return }
        isStarting = true
        cancelRequested = false

        audio.requestPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.permissionDenied = true
                    self.isStarting = false
                    return
                }
                guard !self.cancelRequested else {
                    self.isStarting = false
                    return
                }

                // Off the main thread. setActive and AVAudioEngine.start both
                // block, and doing them inline froze the whole screen — the
                // player, the scroll and the button that would have stopped it.
                let started = await self.startEngineOffMain()

                self.isStarting = false
                guard started, !self.cancelRequested else {
                    if started { await self.stopEngineOffMain() }
                    return
                }
                self.begin()

                if let title = self.pendingRecordingTitle {
                    self.pendingRecordingTitle = nil
                    let url = Recordings.newFileURL(title: title)
                    do {
                        try self.audio.startWriting(
                            to: url,
                            sampleRate: self.audio.currentSampleRate
                        )
                        self.recordingURL = url
                    } catch {
                        self.recordingError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Abandons a start that has not finished yet. The engine may still be
    /// coming up on the background queue, so this records the intent and the
    /// start path tears down whatever it managed to bring up.
    func cancelStart() {
        guard isStarting else { return }
        cancelRequested = true
    }

    /// Starts capture and writes it to a file at the same time.
    ///
    /// The recording is the same mono channel the analyser reads, so what is
    /// kept is exactly what was heard.
    /// Brings the engine up without writing or analysing.
    ///
    /// So the route banner and the level meter are live before you commit to
    /// recording — which is how you confirm the interface is the input, rather
    /// than finding out forty minutes later.
    func startMonitoring() {
        guard !isRecording, !isStarting else { return }
        analyzes = false
        pendingRecordingTitle = nil
        recordingError = nil
        start()
    }

    func startRecordingToFile(title: String, analyzing: Bool = true) {
        analyzes = analyzing
        pendingRecordingTitle = title
        recordingError = nil
        start()
    }

    func stop() {
        analyzes = true
        cancelRequested = true
        isRecording = false
        isStarting = false
        keyUpdateTimer?.invalidate()
        keyUpdateTimer = nil
        Task { await stopEngineOffMain() }
    }

    private func startEngineOffMain() async -> Bool {
        let engine = audio
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try engine.start()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func stopEngineOffMain() async {
        let engine = audio
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                engine.stop()
                continuation.resume()
            }
        }
    }

    // MARK: - Internal

    private func begin() {
        // Force a rebuild on the next buffer so a route change is picked up.
        configuredSampleRate = 0
        detector.reset()
        hmm.reset()
        keyEstimator.reset()
        history.removeAll()
        currentChord = nil
        detectedKey = nil
        lastReported = nil
        latestBass = nil
        startTime = Date()
        isRecording = true

        keyUpdateTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.detectedKey = self.keyEstimator.displayString()
            }
        }
    }

    private func handle(chroma pcp: [Float], bass bassResult: BassDetector.Result?) {
        guard let position = currentPosition() else { return }
        keyEstimator.add(chroma: pcp)

        if let bassResult, bassResult.strength >= bassStrengthFloor {
            latestBass = bassResult
        }

        let similarities = detector.similarities(from: pcp)
        guard !similarities.isEmpty else { return }
        confidence = similarities.max() ?? 0

        // Viterbi over a rolling window, rather than the arg-max of a single
        // frame — this is what stops the readout flickering between
        // near-identical chords.
        guard var chord = hmm.step(similarities: similarities) else { return }

        // Attach a slash bass ONLY when the detected bass is a tone of the
        // chord we just identified.
        //
        // The previous version stamped a slash on whenever the bass differed
        // from the root at all, so every misread of a weak bass signal became
        // a bogus inversion — G/B, C/E, D/F# everywhere. An inversion is a
        // strong claim; require the note to actually belong to the chord.
        if let bass = latestBass, bass.strength >= bassStrengthFloor {
            let tones = Self.pitchClasses(of: chord)
            if bass.pitchClass != chord.root && tones.contains(bass.pitchClass) {
                chord.bass = bass.pitchClass
            }
        }

        currentChord = chord

        if chord != lastReported {
            lastReported = chord
            history.append(DetectedChord(
                chord: chord,
                timestamp: position,
                confidence: Double(confidence)
            ))
        }
    }

    /// The player's position when there is one, otherwise elapsed time — so
    /// the standalone 라이브 분석 screen, which has no video, still works.
    private func currentPosition() -> Double? {
        if let positionProvider { return positionProvider() }
        guard let startTime else { return nil }
        return Date().timeIntervalSince(startTime)
    }

    /// Pitch classes belonging to a chord, used to reject bass notes that are
    /// not part of it.
    private static func pitchClasses(of chord: Chord) -> Set<Int> {
        let intervals: [Int]
        switch chord.quality {
        case .major:      intervals = [0, 4, 7]
        case .minor:      intervals = [0, 3, 7]
        case .dominant7:  intervals = [0, 4, 7, 10]
        case .major7:     intervals = [0, 4, 7, 11]
        case .minor7:     intervals = [0, 3, 7, 10]
        case .sus2:       intervals = [0, 2, 7]
        case .sus4:       intervals = [0, 5, 7]
        case .add9:       intervals = [0, 2, 4, 7]
        case .major9:     intervals = [0, 2, 4, 7, 11]
        case .minor9:     intervals = [0, 2, 3, 7, 10]
        case .dominant9:  intervals = [0, 2, 4, 7, 10]
        case .dominant7sus4: intervals = [0, 5, 7, 10]
        case .sixth:      intervals = [0, 4, 7, 9]
        case .minor6:     intervals = [0, 3, 7, 9]
        case .diminished: intervals = [0, 3, 6]
        case .augmented:  intervals = [0, 4, 8]
        }
        return Set(intervals.map { ($0 + chord.root) % 12 })
    }

    // MARK: - Export

    /// Finalises into a Session, which ChordSheetView and ChordSheetPDF take.
    func buildSession(title: String, url: URL?) -> Session {
        Session(
            title: title.isEmpty ? "Untitled" : title,
            youTubeURL: url,
            detectedKey: detectedKey,
            createdAt: Date(),
            // Sorted because the timestamps now come from the video: seek
            // backwards mid-session and the raw history is out of order.
            chords: history
                .sorted { $0.timestamp < $1.timestamp }
                .map { SessionChord(chord: $0.chord, timestamp: $0.timestamp) }
        )
    }
}
