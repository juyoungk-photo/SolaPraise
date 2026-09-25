//
//  RecorderView.swift
//  SolaPraise
//
//  Recording the line input to a file.
//
//  Separate from 코드 감지 because the two jobs want different screens. Chord
//  detection wants the chord huge and everything else small; a recording wants
//  the level, the clock and the input route, and nothing else — you are
//  glancing at it from behind an instrument, checking that it is still going.
//
//  Nothing here touches YouTube. This is the interface's own input: a service,
//  a rehearsal, an instrument.
//

import SwiftUI
import SwiftData
import AVFoundation

struct RecorderView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var analyzer: AudioFileAnalyzer

    @StateObject private var detection = DetectionSession()
    @State private var title = ""
    @State private var items: [Recordings.Item] = []
    @State private var playing: URL?
    @State private var player: AVAudioPlayer?

    private var audio: AudioEngine { detection.audio }
    private var isRecording: Bool { audio.isWritingFile }

    var body: some View {
        List {
            Section {
                InputSourceBanner(audio: audio)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } footer: {
                Text(readiness)
            }

            Section {
                TextField("이름 (비워 두면 날짜)", text: $title)
                    .disabled(isRecording)

                if isRecording {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text(clock(audio.recordedSeconds))
                            .font(.title3.monospacedDigit())
                        Spacer()
                        Text(sizeEstimate)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    if isRecording { stop() } else { start() }
                } label: {
                    Label(isRecording ? "정지" : "녹음 시작",
                          systemImage: isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
                .disabled(detection.isStarting)

                if let message = detection.recordingError {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }

                if analyzer.isAnalyzing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: analyzer.progress)
                        HStack {
                            Text(analyzer.stage)
                            Spacer()
                            Button("취소") { analyzer.cancel() }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                if let message = analyzer.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("입력 그대로, 32비트 부동소수점으로 저장합니다. 리샘플링도 압축도 없습니다. 분당 약 11MB.")
            }

            if !items.isEmpty {
                Section("녹음") {
                    ForEach(items) { item in
                        row(item)
                    }
                    .onDelete { offsets in
                        for index in offsets where items.indices.contains(index) {
                            if playing == items[index].url { stopPlayback() }
                            Recordings.delete(items[index])
                        }
                        items = Recordings.all()
                    }
                }
            }
        }
        .navigationTitle("녹음")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            items = Recordings.all()
            // Monitor only. Starting a recording and immediately stopping it
            // would not have worked: the engine comes up asynchronously, so
            // the stop lands before the writer exists and the writer is then
            // created anyway — recording without being asked.
            detection.startMonitoring()
        }
        .onDisappear {
            stopPlayback()
            detection.stop()
        }
    }

    // MARK: - Rows

    private func row(_ item: Recordings.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { toggle(item) } label: {
                    Image(systemName: playing == item.url ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    Text("\(item.durationLabel) · \(item.createdAt, format: .dateTime.month().day().hour().minute())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                analyzer.start(url: item.url, title: item.title, context: modelContext)
            } label: {
                Label("코드 분석", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(analyzer.isAnalyzing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - State

    private var readiness: String {
        switch audio.inputSource {
        case .lineIn:
            return "라인 입력이 연결되어 있습니다. 녹음에 가장 좋은 신호입니다."
        case .unknown:
            return "입력 종류를 알 수 없습니다. 레벨이 움직이는지 확인한 뒤 녹음하세요."
        case .bluetooth:
            return "블루투스 입력은 전화 통화용 대역폭이라 녹음에 적합하지 않습니다."
        case .wiredMic, .builtInMic:
            return "마이크로 녹음합니다. 오디오 인터페이스를 연결하면 훨씬 정확해집니다."
        }
    }

    /// 32-bit float mono: 4 bytes a frame.
    private var sizeEstimate: String {
        let rate = audio.inputSampleRate > 0 ? audio.inputSampleRate : 48_000
        let bytes = audio.recordedSeconds * rate * 4
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Actions

    private func start() {
        stopPlayback()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = Recordings.newFileURL(title: name)
        do {
            try audio.startWriting(to: url, sampleRate: audio.currentSampleRate)
        } catch {
            detection.recordingError = error.localizedDescription
        }
    }

    private func stop() {
        audio.stopWriting()
        title = ""
        items = Recordings.all()
    }

    private func toggle(_ item: Recordings.Item) {
        if playing == item.url { stopPlayback(); return }
        stopPlayback()
        // Playback and capture share one session here, which is exactly what
        // .playAndRecord is for — no need to tear the engine down to listen
        // back to what was just recorded.
        player = try? AVAudioPlayer(contentsOf: item.url)
        player?.play()
        playing = item.url
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }
}
