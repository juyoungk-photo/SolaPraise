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
    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var currentLevelDB: Float = -80  // for a mic meter

    // MARK: - Audio objects
    private let engine = AVAudioEngine()
    /// Called on the audio thread with every buffer that arrives from the mic.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

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
        // .allowBluetoothA2DP rather than .allowBluetooth: the latter enables
        // HFP, which drops the link to telephone bandwidth in BOTH directions.
        // Playing a worship track over a Bluetooth speaker through HFP would
        // destroy exactly the harmonic content chord detection depends on.
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRunning else { return }
        try configureSession()

        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)

        // Remove any previous tap just in case.
        input.removeTap(onBus: 0)

        input.installTap(onBus: 0,
                         bufferSize: bufferSize,
                         format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateLevel(from: buffer)
            self.onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()

        DispatchQueue.main.async { self.isRunning = true }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - Level meter

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrtf(sum / Float(max(n, 1)))
        let db = 20 * log10f(max(rms, 1e-7))
        DispatchQueue.main.async {
            // Clamp so the UI meter doesn't spike wildly.
            self.currentLevelDB = max(-80, min(0, db))
        }
    }
}
