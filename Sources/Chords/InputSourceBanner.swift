//
//  InputSourceBanner.swift
//  SolaPraise
//
//  What the analyser is listening to, stated plainly.
//
//  "내장 마이크" and "라인 입력" produce completely different results, and the
//  difference is not audible from the chord readout — a wrong guess just looks
//  like the detector being bad. So the source is named, the device is named,
//  and a live level shows whether anything is arriving at all.
//

import SwiftUI

struct InputSourceBanner: View {
    @ObservedObject var audio: AudioEngine
    /// Compact under a video player; roomier on the standalone screen.
    var compact = false

    private var source: AudioEngine.InputSource { audio.inputSource }

    private var tint: Color {
        switch source {
        case .lineIn:               return .green
        case .wiredMic:             return .yellow
        case .builtInMic, .unknown: return .orange
        case .bluetooth:            return .red
        }
    }

    /// -60…0 dB mapped to 0…1.
    private var level: Double {
        max(0, min(1, (Double(audio.currentLevelDB) + 60) / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: source.symbolName)
                    .font(.caption)

                Text(source.kindLabel)
                    .font(.caption.weight(.semibold))

                if audio.inputSampleRate > 0 {
                    Text("· \(Int(audio.inputSampleRate / 1000))kHz")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                meter
            }
            .foregroundStyle(tint)

            // Both ends, always. "Is the iPad sending audio to the Scarlett,
            // or is the Scarlett sending audio to the iPad?" is not a question
            // with one answer — they are separate paths over the same cable,
            // and only naming both makes that legible.
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.left")
                    .font(.caption2)
                Text("입력")
                    .font(.caption2.weight(.semibold))
                Text(source.label)
                    .font(.caption2)
                    .lineLimit(1)

                Text("·").font(.caption2).foregroundStyle(.tertiary)

                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                Text("출력")
                    .font(.caption2.weight(.semibold))
                Text(audio.outputName)
                    .font(.caption2)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            if !compact, let warning = source.warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InputChannelPicker(audio: audio)
        }
        .padding(compact ? 0 : 10)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    }
            }
        }
    }

    /// The one thing that settles it when the label is not enough: if this
    /// does not move when the band plays, nothing is reaching the app.
    private var meter: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(level > 0.02 ? tint : Color.clear)
                        .frame(width: 44 * level, height: 4)
                }
            Text(audio.currentLevelDB <= -79
                 ? "무신호"
                 : "\(Int(audio.currentLevelDB))dB")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(audio.currentLevelDB <= -79 ? Color.orange : .secondary)
        }
    }
}
