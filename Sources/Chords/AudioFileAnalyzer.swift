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

import Foundation
import AVFoundation
import SwiftData

@MainActor
final class AudioFileAnalyzer: ObservableObject {

    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress: Double = 0
    /// What it is doing right now. Without this a long decode is
    /// indistinguishable from a hang.
    @Published private(set) var stage: String = ""
    @Published private(set) var fileName: String?
    @Published private(set) var detectedKey: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var finished: SavedSong?

    /// Held here rather than by a view.
    ///
    /// A `.task` or a view-owned Task is cancelled the moment its view goes
    /// away, so switching tabs mid-analysis killed the job. The analyser owns
    /// its own work and lives at app level, which is what lets you go and
    /// listen to something while a file is being analysed.
    private var job: Task<Void, Never>?

    /// The hop the DSP is fed at.
    ///
    /// 1024, matching the live path and the harness. It used to read 8192 at a
    /// time — the chroma extractor's entire FFT window — so it analysed one
    /// window per 8192 frames with no overlap, eight times coarser in time
    /// than live detection and measuring something the test harness never
    /// checked. Short chords fell between windows entirely.
    private static let hop: AVAudioFrameCount = 1024

    var isBusy: Bool { isAnalyzing }

    func cancel() {
        job?.cancel()
        job = nil
        isAnalyzing = false
        stage = ""
    }

    /// Starts an analysis that outlives the screen that asked for it.
    func start(url: URL, title: String, context: ModelContext) {
        guard !isAnalyzing else { return }
        job?.cancel()

        isAnalyzing = true
        progress = 0
        stage = "파일 여는 중…"
        fileName = title
        errorMessage = nil
        detectedKey = nil
        finished = nil

        job = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.run(url: url, title: title) { progress, stage in
                Task { @MainActor [weak self] in
                    self?.progress = progress
                    self?.stage = stage
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run { self.isAnalyzing = false; self.stage = "" }
                return
            }

            await MainActor.run {
                self.isAnalyzing = false
                self.stage = ""
                self.progress = 1
                switch outcome {
                case .failure(let message):
                    self.errorMessage = message
                case .success(let session):
                    self.detectedKey = session.detectedKey
                    let song = SavedSong(
                        session: session,
                        sections: SongStructure.detect(chords: session.chords)
                    )
                    context.insert(song)
                    try? context.save()
                    self.finished = song
                }
            }
        }
    }

    enum Outcome {
        case success(Session)
        case failure(String)
    }

    /// The DSP, off the main actor.
    ///
    /// This used to run inside a @MainActor method, so every FFT executed on
    /// the main thread and the interface froze until it was done. The
    /// `await Task.yield()` that was supposed to relieve it fired on
    /// `collected.count % 8 == 0` — a counter that only advances when a chord
    /// CHANGES — so a quiet or steady passage left it stuck on one value and
    /// yielding stopped entirely. Nothing about that could be fixed from the
    /// main thread; it had to leave.
    nonisolated private static func run(
        url: URL,
        title: String,
        report: @escaping @Sendable (Double, String) -> Void
    ) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                return .failure("오디오 파일을 열 수 없습니다: \(error.localizedDescription)")
            }

            let format = file.processingFormat
            let sampleRate = format.sampleRate
            let totalFrames = file.length
            guard totalFrames > 0, sampleRate > 0 else {
                return .failure("빈 오디오 파일입니다.")
            }

            let chroma = NNLSChromaExtractor(sampleRate: sampleRate)
            let bass = BassDetector(sampleRate: sampleRate)
            let detector = ChordDetector(includeSevenths: true)
            let hmm = ChordHMM(chords: detector.chordSpace)
            let keyEstimator = KeyEstimator()

            let duration = Double(totalFrames) / sampleRate
            report(0, "코드 분석 중… 0:00 / \(Self.clock(duration))")

            var collected: [SessionChord] = []
            var lastChord: Chord?
            var framesRead: AVAudioFramePosition = 0
            var sinceReport = 0

            // Read in larger blocks than the DSP hop: file reads are the slow
            // part, the hop is what the analysis needs.
            let blockFrames: AVAudioFrameCount = 16384
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
                  let mono = AVAudioPCMBuffer(
                      pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: 1,
                                               interleaved: false)!,
                      frameCapacity: Self.hop
                  )
            else { return .failure("오디오 버퍼를 만들 수 없습니다.") }

            while framesRead < totalFrames {
                if Task.isCancelled { return .failure("") }

                do { try file.read(into: block, frameCount: blockFrames) }
                catch { break }
                let available = Int(block.frameLength)
                guard available > 0, let source = block.floatChannelData else { break }
                let channels = Int(block.format.channelCount)

                var offset = 0
                while offset < available {
                    let count = min(Int(Self.hop), available - offset)
                    guard let destination = mono.floatChannelData?[0] else { break }
                    mono.frameLength = AVAudioFrameCount(count)

                    // Downmix rather than taking the left channel.
                    //
                    // Reading channel 0 only discarded anything panned right,
                    // which on a worship mix is regularly a guitar or a
                    // keyboard — harmony the detector then never saw.
                    if channels == 1 {
                        memcpy(destination, source[0] + offset, count * MemoryLayout<Float>.size)
                    } else {
                        let scale = 1 / Float(channels)
                        for i in 0 ..< count {
                            var sum: Float = 0
                            for c in 0 ..< channels { sum += source[c][offset + i] }
                            destination[i] = sum * scale
                        }
                    }

                    let position = TimeInterval(framesRead + AVAudioFramePosition(offset)) / sampleRate
                    offset += count

                    guard let pcp = chroma.process(buffer: mono) else { continue }
                    keyEstimator.add(chroma: pcp)

                    let bassResult = bass.process(buffer: mono)
                    let similarities = detector.similarities(from: pcp)
                    guard !similarities.isEmpty,
                          var chord = hmm.step(similarities: similarities) else { continue }

                    if let bassResult, bassResult.strength >= 0.70 {
                        let tones = Self.pitchClasses(of: chord)
                        if bassResult.pitchClass != chord.root,
                           tones.contains(bassResult.pitchClass) {
                            chord.bass = bassResult.pitchClass
                        }
                    }

                    if chord != lastChord {
                        lastChord = chord
                        collected.append(SessionChord(chord: chord, timestamp: position))
                    }
                }

                framesRead += AVAudioFramePosition(available)

                // Driven by frames read, not by chord changes, so the bar
                // moves through silence too.
                sinceReport += available
                if sinceReport >= Int(sampleRate * 2) {
                    sinceReport = 0
                    let done = Double(framesRead) / Double(totalFrames)
                    let at = Double(framesRead) / sampleRate
                    report(done, "코드 분석 중… \(Self.clock(at)) / \(Self.clock(duration))")
                }
            }

            report(0.98, "정리 중…")
            let collapsed = Self.collapseRuns(collected)
            guard !collapsed.isEmpty else {
                return .failure("코드를 찾지 못했습니다. 반주가 뚜렷한 구간이 있는 파일인지 확인해 주세요.")
            }

            return .success(Session(
                title: title,
                youTubeURL: nil,
                detectedKey: keyEstimator.displayString(),
                createdAt: Date(),
                chords: collapsed
            ))
        }.value
    }

    nonisolated private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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
    nonisolated static func collapseRuns(_ items: [SessionChord],
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

    nonisolated private static func pitchClasses(of chord: Chord) -> Set<Int> {
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
