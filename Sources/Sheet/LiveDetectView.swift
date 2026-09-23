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

    @StateObject private var detection = DetectionSession()
    @State private var title = ""
    @State private var savedSong: SavedSong?

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
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: detection.inputSource.isHighQuality ? "cable.connector" : "mic.fill")
                Text(detection.inputSource.label)
                if detection.inputSampleRate > 0 {
                    Text("· \(Int(detection.inputSampleRate / 1000))kHz").monospacedDigit()
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(detection.inputSource.isHighQuality ? Color.green : Color.orange)

            if let warning = detection.inputSource.warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    detection.start()
                } label: {
                    Label("감지 시작", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(detection.permissionDenied)
            }
        }
        .padding(.horizontal)
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
        savedSong = song
    }
}
