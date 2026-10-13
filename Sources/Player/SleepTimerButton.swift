//
//  SleepTimerButton.swift
//  SolaPraise
//
//  The player's 취침 button: stop playing in 10–30 minutes, or when this
//  video ends. Shows the time left while it is counting.
//

import SwiftUI

struct SleepTimerButton: View {
    @EnvironmentObject private var host: PlayerHost

    static let choices = [10, 15, 20, 30, 45, 60]

    var body: some View {
        Menu {
            ForEach(Self.choices, id: \.self) { minutes in
                Button("\(minutes)분 후") { host.setSleepTimer(minutes: minutes) }
            }
            Button("이 영상 끝나면") { host.sleepAtEndOfVideo() }
            if host.isSleepTimerOn {
                Divider()
                Button("끄기", role: .destructive) { host.cancelSleepTimer() }
            }
        } label: {
            label
        }
        .buttonStyle(.bordered)
        .tint(host.isSleepTimerOn ? .indigo : nil)
        .accessibilityLabel(host.isSleepTimerOn ? "취침 타이머 켜짐" : "취침 타이머")
    }

    @ViewBuilder
    private var label: some View {
        if let deadline = host.sleepDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(Self.remaining(until: deadline, now: context.date), systemImage: "moon.zzz.fill")
                    .monospacedDigit()
            }
        } else if host.sleepsAtEnd {
            Label("끝나면 정지", systemImage: "moon.zzz.fill")
        } else {
            Label("취침", systemImage: "moon.zzz")
        }
    }

    /// 「19:58」, counting down.
    static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
