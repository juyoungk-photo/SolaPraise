//
//  AudioFileAnalyzer.swift
//  SolaPraise
//
//  Chord detection from an audio file you own — a church service recording,
//  a practice take, a track you bought.
//
//  WHY THIS EXISTS: there is no legitimate way to analyse YouTube audio on
//  iOS. §III.I.7 forbids separating audio from YouTube content, iOS has no
//  system-audio capture, and the microphone path is hopeless when the source
//  is the phone's own speaker — a tiny driver with almost no bass response
//  feeding a mic inches away, and bass is exactly what chord detection needs.
//
//  A file sidesteps all of it: full bandwidth, no echo, no rights question,
//  and it analyses far faster than real time because nothing has to be played.
//

import Foundation
import AVFoundation

@MainActor
final class AudioFileAnalyzer: ObservableObject {

    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var detectedKey: String?
    @Published private(set) var chords: [SessionChord] = []
    @Published private(set) var errorMessage: String?

    /// Frames per analysis window. Matches the live path's cadence closely
    /// enough that the detector's hysteresis behaves the same way.
    private let chunkFrames: AVAudioFrameCount = 8192

    func analyze(url: URL, title: String) async -> Session? {
        isAnalyzing = true
        progress = 0
        errorMessage = nil
        chords = []
        detectedKey = nil
        defer { isAnalyzing = false }

        // Security-scoped access is required for files chosen from the Files
        // app; without it the read fails with a permissions error.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            errorMessage = "오디오 파일을 열 수 없습니다: \(error.localizedDescription)"
            return nil
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0 else {
            errorMessage = "빈 오디오 파일입니다."
            return nil
        }

        // Extractors are built for the file's own rate, so nothing is resampled.
        let chroma = NNLSChromaExtractor(sampleRate: sampleRate)
        let bass = BassDetector(sampleRate: sampleRate)
        let detector = ChordDetector(includeSevenths: true)
        let hmm = ChordHMM(chords: detector.chordSpace)
        let keyEstimator = KeyEstimator()

        var collected: [SessionChord] = []
        var lastChord: Chord?
        var framesRead: AVAudioFramePosition = 0

        while framesRead < totalFrames {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }

            let timestamp = TimeInterval(framesRead) / sampleRate
            framesRead += AVAudioFramePosition(buffer.frameLength)

            guard let pcp = chroma.process(buffer: buffer) else { continue }
            keyEstimator.add(chroma: pcp)

            let bassResult = bass.process(buffer: buffer)
            let similarities = detector.similarities(from: pcp)
            guard !similarities.isEmpty, var chord = hmm.step(similarities: similarities) else { continue }

            if let bassResult, bassResult.strength >= 0.70 {
                let tones = Self.pitchClasses(of: chord)
                if bassResult.pitchClass != chord.root && tones.contains(bassResult.pitchClass) {
                    chord.bass = bassResult.pitchClass
                }
            }

            if chord != lastChord {
                lastChord = chord
                collected.append(SessionChord(chord: chord, timestamp: timestamp))
            }

            // Yield periodically so the progress bar actually moves.
            if collected.count % 8 == 0 {
                progress = Double(framesRead) / Double(totalFrames)
                await Task.yield()
            }
        }

        progress = 1
        collected = Self.collapseRuns(collected)
        chords = collected
        detectedKey = keyEstimator.displayString()

        guard !collected.isEmpty else {
            errorMessage = "코드를 찾지 못했습니다. 반주가 뚜렷한 구간이 있는 파일인지 확인해 주세요."
            return nil
        }

        return Session(
            title: title,
            youTubeURL: nil,
            detectedKey: detectedKey,
            createdAt: Date(),
            chords: collected
        )
    }

    /// Collapses consecutive readings that share a root into one chord.
    ///
    /// At a chord boundary the previous chord is still ringing under the new
    /// one, so the detector reads the blend — C decaying under F genuinely is
    /// Fmaj7. Verified on a synthetic C-F-G-Am progression, where every
    /// boundary produced exactly one such artefact and the run looked like
    /// Fmaj7 → F → Fadd9 for a single F chord.
    ///
    /// The ROOT is the dependable part of the estimate, so consecutive entries
    /// sharing a root become one chord, taking whichever quality was held
    /// longest. Filtering purely on duration does not work: a real chord is
    /// often followed immediately by its own artefact, making it look brief.
    ///
    /// NOTE: quality selection is validated only against that synthetic case.
    /// On real recordings it may still pick an artefact's quality over the
    /// true one, which is why the lead sheet stays editable.
    static func collapseRuns(_ items: [SessionChord],
                             minimumHold: TimeInterval = 0.8) -> [SessionChord] {
        guard items.count > 1 else { return items }

        // Group consecutive entries by root.
        var groups: [[(item: SessionChord, duration: TimeInterval)]] = []
        for (index, item) in items.enumerated() {
            let end = index + 1 < items.count
                ? items[index + 1].timestamp
                : item.timestamp + minimumHold
            let entry = (item: item, duration: end - item.timestamp)

            if var last = groups.last, last.first?.item.root == item.root {
                last.append(entry)
                groups[groups.count - 1] = last
            } else {
                groups.append([entry])
            }
        }

        var out: [SessionChord] = []
        for group in groups {
            let total = group.reduce(0) { $0 + $1.duration }
            guard total >= minimumHold else { continue }
            guard let dominant = group.max(by: { $0.duration < $1.duration }) else { continue }
            // Keep the group's start time, but the longest-held quality.
            out.append(SessionChord(
                chord: dominant.item.asChord,
                timestamp: group[0].item.timestamp
            ))
        }
        return out.isEmpty ? items : out
    }

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
}
