//
//  InputChannelPicker.swift
//  SolaPraise
//
//  Which input the analyser listens to.
//
//  Only shown when there is a choice to make. A phone microphone is one
//  channel and needs no picker; an audio interface has several, and on a
//  Scarlett 8i6 neither the line inputs nor Loopback are channel 1 — so
//  without this the app listened to an empty mic preamp and reported nothing.
//

import SwiftUI

struct InputChannelPicker: View {
    @ObservedObject var audio: AudioEngine

    var body: some View {
        if audio.channelCount > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("입력 채널")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if audio.selectedChannel == AudioEngine.autoChannel {
                        Text("· 자동 선택: \(audio.resolvedChannel + 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(
                            label: "자동",
                            isSelected: audio.selectedChannel == AudioEngine.autoChannel,
                            level: nil
                        ) {
                            audio.selectedChannel = AudioEngine.autoChannel
                        }

                        ForEach(0 ..< audio.channelCount, id: \.self) { channel in
                            chip(
                                label: "\(channel + 1)",
                                isSelected: audio.selectedChannel == channel,
                                level: level(channel)
                            ) {
                                audio.selectedChannel = channel
                            }
                        }
                    }
                }
            }
        }
    }

    /// -80…0 dB mapped to 0…1, with the bottom 20 dB thrown away — below that
    /// a channel is silent for our purposes and a twitching bar only suggests
    /// signal that is not there.
    private func level(_ channel: Int) -> Double {
        guard audio.channelLevelsDB.indices.contains(channel) else { return 0 }
        let db = Double(audio.channelLevelsDB[channel])
        return max(0, min(1, (db + 60) / 60))
    }

    private func chip(
        label: String,
        isSelected: Bool,
        level: Double?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(label)
                    .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .regular))
                if let level {
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 26, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(level > 0.02 ? Color.green : Color.clear)
                                .frame(width: 26 * level, height: 3)
                        }
                }
            }
            .frame(minWidth: 38)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill))
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
