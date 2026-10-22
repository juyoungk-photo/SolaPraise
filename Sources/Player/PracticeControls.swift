//
//  PracticeControls.swift
//  SolaPraise
//
//  연습: the song again, or one section over and over — under the player,
//  and on the chart while it is open, so a part can be learned without
//  going back to the video to replay it.
//
//  WHY: learning Sunday's set meant dragging YouTube's scrubber back to
//  the bridge every time it ended, and the chart, opened full screen, had
//  no way to touch the player at all. A section is marked while it plays —
//  A where it starts, B where it ends — the way a practice loop is set on
//  a looper pedal.
//

import SwiftUI

struct PracticeControls: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// Play/pause and ten seconds either way: on the chart, where YouTube's
    /// own controls cannot be reached.
    var withTransport = false

    var body: some View {
        HStack(spacing: 10) {
            if withTransport {
                Button { coordinator.skip(forward: false) } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("10초 뒤로")
                Button { coordinator.togglePlay() } label: {
                    Image(systemName: coordinator.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 22)
                }
                .accessibilityLabel(coordinator.state == .playing ? "일시정지" : "재생")
                Button { coordinator.skip(forward: true) } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("10초 앞으로")
            }

            Button { coordinator.repeatsSong.toggle() } label: {
                Label("한 곡 반복", systemImage: coordinator.repeatsSong ? "repeat.1.circle.fill" : "repeat.1")
            }
            .tint(coordinator.repeatsSong ? .orange : nil)
            .accessibilityAddTraits(coordinator.repeatsSong ? .isSelected : [])

            Button { coordinator.markLoop() } label: {
                Label(loopLabel, systemImage: coordinator.loopEnd != nil ? "arrow.triangle.2.circlepath.circle.fill"
                                                                         : "arrow.triangle.2.circlepath")
                    .monospacedDigit()
            }
            .tint(coordinator.loopStart != nil ? .orange : nil)
            .accessibilityHint(loopHint)
        }
        .labelStyle(.titleAndIcon)
    }

    /// 「구간 A」 → 「A 0:42 — B?」 → 「0:42–1:15 반복」.
    private var loopLabel: String {
        guard let a = coordinator.loopStart else { return "구간 A" }
        guard let b = coordinator.loopEnd else { return "A \(Self.clock(a)) — B" }
        return "\(Self.clock(a))–\(Self.clock(b)) 반복"
    }

    private var loopHint: String {
        if coordinator.loopStart == nil { return "지금 위치를 반복 구간의 시작으로" }
        if coordinator.loopEnd == nil { return "지금 위치를 반복 구간의 끝으로" }
        return "구간 반복 끄기"
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
