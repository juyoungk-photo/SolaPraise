//
//  PracticeControls.swift
//  SolaPraise
//
//  The player's transport on the chart — play, pause, ten seconds either
//  way — while the chart is open full screen and YouTube's own controls
//  cannot be reached.
//
//  한 곡 반복 and 구간 반복 were here, and under the player as a row of
//  their own; taken down — not wanted for now, and not worth a row. The
//  player still knows how (PlayerCoordinator.repeatsSong, markLoop).
//

import SwiftUI

struct PracticeControls: View {
    @ObservedObject var coordinator: PlayerCoordinator
    var body: some View {
        HStack(spacing: 10) {
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
    }
}
