//
//  LiveDetectView.swift
//  SolaPraise
//
//  Standalone chord detection from whatever the device is listening to —
//  a line-level feed from an audio interface at practice, or the microphone.
//
//  This is separate from the player on purpose. Detecting from the phone's own
//  speaker never worked and never could; this screen is for a real signal.
//

import SwiftUI
import SwiftData

struct LiveDetectView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var analyzer: AudioFileAnalyzer

    @StateObject private var detection = DetectionSession()
    @State private var title = ""
    @State private var savedSong: SavedSong?
    @AppStorage("live.keepsRecording") private var keepsRecording = false

    var body: some View {
        VStack(spacing: 18) {
            inputBanner

            Spacer()

            Text(detection.currentChord?.symbol() ?? (detection.isRecording ? "듣는 중…" : "준비됨"))
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: detection.currentChord)

            if let key = detection.detectedKey {
                Text("Key \(key)").font(.headline).foregroundStyle(.secondary)
            }

            ProgressView(value: Double(detection.confidence))
                .frame(width: 180)

            Text("^[\(detection.history.count) chord](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            recentChords

            TextField("곡 제목", text: $title)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            recordToggle
            controls
        }
        .padding(.vertical)
        .navigationTitle("코드 감지")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $savedSong) { song in
            LeadSheetView(song: song)
        }
        .onDisappear { detection.stop() }
    }

    // MARK: - Pieces

    private var inputBanner: some View {
        InputSourceBanner(audio: detection.audio)
            .padding(.horizontal)
    }

    private var recentChords: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(detection.history.suffix(12)) { detected in
                    Text(detected.chord.symbol())
                        .font(.subheadline.weight(.semibold).monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.secondarySystemBackground))
                        )
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 44)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if detection.isRecording {
                Button {
                    detection.stop()
                    saveSheet()
                } label: {
                    Label("정지하고 악보 만들기", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    if keepsRecording {
                        detection.startRecordingToFile(title: title)
                    } else {
                        detection.start()
                    }
                } label: {
                    Label(keepsRecording ? "녹음하며 감지" : "감지 시작",
                          systemImage: keepsRecording ? "record.circle" : "waveform")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(keepsRecording ? .red : .accentColor)
                .disabled(detection.permissionDenied || detection.isStarting)
            }
        }
        .padding(.horizontal)
    }

    /// Keeping the capture is what makes a second pass possible.
    ///
    /// Live detection gets exactly one attempt at a performance. The file path
    /// re-reads the same audio faster than real time, with overlapping windows
    /// and no room noise, so a kept recording is both a better analysis today
    /// and one that can be redone tomorrow.
    private var recordToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $keepsRecording) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("녹음해서 보관").font(.subheadline)
                    Text("입력 그대로 저장 — 변환도 압축도 없습니다")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(detection.isRecording)

            if detection.audio.isWritingFile {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text(clock(detection.audio.recordedSeconds))
                        .font(.caption.monospacedDigit())
                    Spacer()
                }
            }
            if let message = detection.recordingError {
                Text(message).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func saveSheet() {
        guard !detection.history.isEmpty else { return }
        let session = detection.buildSession(
            title: title.isEmpty ? "코드 감지 \(Date().formatted(date: .abbreviated, time: .shortened))" : title,
            url: nil
        )
        let song = SavedSong(
            session: session,
            sections: SongStructure.detect(chords: session.chords)
        )
        modelContext.insert(song)
        try? modelContext.save()

        // A kept capture gets re-analysed straight away: same audio, but with
        // the overlapping windows the live path cannot afford in real time.
        if let url = detection.recordingURL {
            analyzer.start(url: url, title: session.title, context: modelContext)
        }
        savedSong = song
    }
}
