//
//  AudioEngine.swift
//  PraiseTheLord
//
//  Wraps AVAudioEngine. Requests mic permission, installs a tap on the
//  input node, and streams 1024-sample mono Float32 chunks to a callback.
//
//  The DSP pipeline (ChromaExtractor / ChordDetector) consumes those chunks.
//

import AVFoundation
import Combine

final class AudioEngine: ObservableObject {

    // MARK: - Published state for the UI
    @Published private(set) var isRunning: Bool = false

    /// The engine's real state, updated synchronously on whichever queue
    /// start/stop was called from.
    ///
    /// `isRunning` is published, so it is only set on the main queue one hop
    /// later. Guarding stop() on it meant a cancel arriving right after a
    /// start saw false and returned without stopping anything, leaving the
    /// microphone live with nothing reading it.
    private var engineStarted = false
    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var currentLevelDB: Float = -80  // for a mic meter

    /// How many input channels the current route offers.
    ///
    /// A phone mic is 1. A Scarlett 8i6 is 6 or more, and its Loopback and its
    /// line inputs are *not* channel 0 — so reading the first channel and
    /// calling it "the input" analysed an empty mic preamp and showed nothing,
    /// with no error to explain why.
    @Published private(set) var channelCount: Int = 1

    /// Which channel the DSP reads. -1 means "pick the loudest".
    @Published var selectedChannel: Int = AudioEngine.storedChannel {
        didSet {
            UserDefaults.standard.set(selectedChannel, forKey: Self.channelKey)
            if selectedChannel >= 0 { resolvedChannel = selectedChannel }
        }
    }

    /// The channel actually in use, once auto-selection has settled.
    @Published private(set) var resolvedChannel: Int = 0

    /// Per-channel level, so the picker can show which input has signal.
    @Published private(set) var channelLevelsDB: [Float] = [-80]

    static let autoChannel = -1
    private static let channelKey = "chords.inputChannel"
    private static var storedChannel: Int {
        UserDefaults.standard.object(forKey: channelKey) as? Int ?? autoChannel
    }

    /// Energy gathered per channel while auto-selection is still deciding.
    private var autoEnergy: [Float] = []
    private var autoFrames = 0
    /// About a second at 1024 frames — long enough to tell a live input from a
    /// silent one, short enough not to miss the start of a song.
    private let autoFramesNeeded = 45
    private var monoScratch: AVAudioPCMBuffer?
    private var meterTick = 0

    // MARK: - Audio objects
    private let engine = AVAudioEngine()
    /// Called on the audio thread with every buffer that arrives from the mic.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var routeObserver: NSObjectProtocol?

    // Hardware buffer size in frames. 1024 @ 44.1kHz ≈ 23 ms latency.
    private let bufferSize: AVAudioFrameCount = 1024

    /// What the engine is currently hearing. Surfaced because the difference
    /// between a line-level feed and the built-in microphone is the difference
    /// between a usable chord chart and guesswork.
    enum InputSource {
        case lineIn(String)      // USB / audio interface — the good case
        case wiredMic(String)
        case builtInMic
        case bluetooth(String)   // HFP: telephone bandwidth, unusable for music
        case unknown

        var isHighQuality: Bool {
            if case .lineIn = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .lineIn(let name):    return name
            case .wiredMic(let name):  return name
            case .builtInMic:          return "내장 마이크"
            case .bluetooth(let name): return "\(name) (블루투스)"
            case .unknown:             return "알 수 없음"
            }
        }

        var warning: String? {
            switch self {
            case .lineIn:   return nil
            case .wiredMic: return "외장 마이크로 듣는 중입니다. 스피커에 가까이 두세요."
            case .builtInMic:
                return "내장 마이크로 듣는 중입니다. 폰 스피커 소리를 폰 마이크로 듣는 방식은 저음이 거의 잡히지 않아 코드가 부정확합니다. 오디오 인터페이스로 라인 입력을 연결하면 크게 좋아집니다."
            case .bluetooth:
                return "블루투스 마이크는 전화 통화용 대역폭이라 음악 분석에 적합하지 않습니다."
            case .unknown:  return nil
            }
        }
    }

    /// Current input route and its sample rate.
    static func currentInput() -> (source: InputSource, sampleRate: Double) {
        let session = AVAudioSession.sharedInstance()
        let rate = session.sampleRate
        guard let port = session.currentRoute.inputs.first else {
            return (.unknown, rate)
        }
        let name = port.portName
        switch port.portType {
        case .usbAudio:
            return (.lineIn(name), rate)
        case .headsetMic:
            return (.wiredMic(name), rate)
        case .builtInMic:
            return (.builtInMic, rate)
        case .bluetoothHFP:
            return (.bluetooth(name), rate)
        default:
            return (.lineIn(name), rate)
        }
    }

    // MARK: - Permission

    /// Call from UI when user taps "Start". Handles iOS 17+ and older APIs.
    func requestPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    completion(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    completion(granted)
                }
            }
        }
    }

    // MARK: - Session

    /// Configure the audio session so we can record *while* the in-app
    /// YouTube player plays sound out of the speaker. `.mixWithOthers`
    /// prevents us from ducking the YouTube audio.
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .measurement disables the input chain iOS applies by default —
        // automatic gain control, EQ and noise suppression. Those are tuned
        // for speech and actively damage music before the DSP ever sees it.
        //
        // But it disables the OUTPUT chain too, and on the built-in speaker
        // that processing is most of the loudness. Choosing it unconditionally
        // made the phone quietly play a song to a microphone that could barely
        // hear it — clean input of almost nothing. So it is used only when the
        // input is a real line, where fidelity is the thing that matters and
        // the speaker usually isn't in the loop at all.
        let mode: AVAudioSession.Mode =
            Self.currentInput().source.isHighQuality ? .measurement : .default

        // .allowBluetoothA2DP rather than .allowBluetooth: the latter enables
        // HFP, which drops the link to telephone bandwidth in BOTH directions.
        // Playing a worship track over a Bluetooth speaker through HFP would
        // destroy exactly the harmonic content chord detection depends on.
        try session.setCategory(.playAndRecord,
                                mode: mode,
                                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
        // .playAndRecord otherwise routes to the receiver, which would send
        // the song to the earpiece while the microphone listens to the room.
        try? session.overrideOutputAudioPort(.speaker)
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !engineStarted else { return }
        try configureSession()
        observeRouteChanges()

        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)

        // Remove any previous tap just in case.
        input.removeTap(onBus: 0)

        let channels = Int(nativeFormat.channelCount)
        DispatchQueue.main.async {
            self.channelCount = channels
            self.channelLevelsDB = Array(repeating: -80, count: max(channels, 1))
        }
        autoEnergy = Array(repeating: 0, count: max(channels, 1))
        autoFrames = 0
        meterTick = 0
        monoScratch = nil
        if selectedChannel >= 0 {
            let fixed = min(selectedChannel, max(channels - 1, 0))
            DispatchQueue.main.async { self.resolvedChannel = fixed }
        }

        input.installTap(onBus: 0,
                         bufferSize: bufferSize,
                         format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.measureChannels(buffer)
            guard let mono = self.mono(from: buffer) else { return }
            self.updateLevel(from: mono)
            self.onBuffer?(mono)
        }

        engine.prepare()
        try engine.start()
        engineStarted = true

        DispatchQueue.main.async { self.isRunning = true }
    }

    func stop() {
        guard engineStarted else { return }
        engineStarted = false
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async { self.isRunning = false }
    }

    /// A tap is installed with the input's format at that moment, so plugging
    /// in a USB interface mid-session leaves it reading a format the hardware
    /// no longer produces. Restarting is the only reliable fix.
    private func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self, self.engineStarted else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engineStarted = false
            DispatchQueue.main.async {
                self.isRunning = false
                try? self.start()
            }
        }
    }

    // MARK: - Channel selection

    /// Copies one channel into a mono buffer for the DSP.
    ///
    /// The chroma and bass stages both read `floatChannelData[0]`, so handing
    /// them a six-channel buffer meant they read input 1 and nothing else.
    /// The scratch buffer is reused: this runs about 47 times a second.
    private func mono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData else { return nil }
        let count = Int(buffer.format.channelCount)
        guard count > 0 else { return nil }
        if count == 1 { return buffer }

        let index = min(max(currentChannel, 0), count - 1)
        let frames = Int(buffer.frameLength)

        if monoScratch == nil || monoScratch!.frameCapacity < buffer.frameLength {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: buffer.format.sampleRate,
                                             channels: 1,
                                             interleaved: false),
                  let scratch = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: buffer.frameCapacity)
            else { return nil }
            monoScratch = scratch
        }
        guard let out = monoScratch, let destination = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        memcpy(destination[0], source[index], frames * MemoryLayout<Float>.size)
        return out
    }

    /// Read on the audio thread, so it does not wait for a main-queue hop.
    private var currentChannel: Int {
        if selectedChannel >= 0 { return selectedChannel }
        guard !autoEnergy.isEmpty else { return 0 }
        var best = 0
        for i in 1 ..< autoEnergy.count where autoEnergy[i] > autoEnergy[best] { best = i }
        return best
    }

    /// Per-channel RMS, both to drive the picker's meters and to decide which
    /// input is actually carrying the music.
    private func measureChannels(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard count > 0, frames > 0 else { return }

        var levels = [Float](repeating: -80, count: count)
        if autoEnergy.count != count { autoEnergy = Array(repeating: 0, count: count) }

        for channel in 0 ..< count {
            var sum: Float = 0
            let samples = data[channel]
            for i in 0 ..< frames { sum += samples[i] * samples[i] }
            let rms = sqrtf(sum / Float(frames))
            levels[channel] = max(-80, min(0, 20 * log10f(max(rms, 1e-7))))
            if autoFrames < autoFramesNeeded { autoEnergy[channel] += rms }
        }

        if autoFrames < autoFramesNeeded { autoFrames += 1 }
        let resolved = currentChannel

        // Roughly ten updates a second, not forty-seven. Meters do not need
        // per-buffer resolution, and publishing at buffer rate re-renders the
        // whole panel faster than anyone can read it.
        meterTick += 1
        guard meterTick % 5 == 0 else { return }

        DispatchQueue.main.async {
            self.channelLevelsDB = levels
            if self.resolvedChannel != resolved { self.resolvedChannel = resolved }
        }
    }

    // MARK: - Level meter

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrtf(sum / Float(max(n, 1)))
        let db = 20 * log10f(max(rms, 1e-7))
        guard meterTick % 5 == 0 else { return }
        DispatchQueue.main.async {
            // Clamp so the UI meter doesn't spike wildly.
            self.currentLevelDB = max(-80, min(0, db))
        }
    }
}
