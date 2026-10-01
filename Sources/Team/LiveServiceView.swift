//
//  LiveServiceView.swift
//  SolaPraise
//
//  Running the service: what we are on, what is next, and how we are doing
//  against the clock.
//
//  HOW IT SYNCS, AND WHAT THAT COSTS: the team sheet has no push, so one
//  person advances and everyone else finds out by polling. Followers run a
//  few seconds behind, which is right for "what is next" and wrong for a
//  cue — so the screen shows when it last heard rather than implying it is
//  live to the second. Anything tighter needs a real-time backend, which is
//  the thing this app has gone out of its way not to require.
//

import SwiftUI

struct LiveServiceView: View {
    let service: TeamService

    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var lastHeard: Date?
    @State private var startedAt = Date()
    @State private var now = Date()
    @State private var poller: Task<Void, Never>?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var items: [PlanItem] { team.plan(for: service) }
    private var currentOrder: Int {
        team.liveOrder[Calendar.current.startOfDay(for: service.date)]
            ?? items.first?.order ?? 0
    }
    private var currentIndex: Int? { items.firstIndex { $0.order == currentOrder } }
    private var current: PlanItem? { currentIndex.map { items[$0] } }
    private var next: PlanItem? {
        guard let i = currentIndex, i + 1 < items.count else { return nil }
        return items[i + 1]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 0)
                currentBlock
                Spacer(minLength: 0)
                nextBlock
                controls
            }
            .padding(24)
            .foregroundStyle(.white)
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        // A service runs an hour and nobody is touching the screen.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            poller?.cancel()
        }
        .onReceive(tick) { now = $0 }
        .task { await startPolling() }
        .onChange(of: currentOrder) { _, _ in startedAt = Date() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title).font(.headline)
                if let by = team.liveUpdatedBy[Calendar.current.startOfDay(for: service.date)],
                   !by.isEmpty {
                    Text("\(by) 진행").font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
            // Says when it last heard, not "live" — because it is not.
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.clock.string(from: now))
                    .font(.title3.monospacedDigit())
                if let lastHeard {
                    Text("\(Int(now.timeIntervalSince(lastHeard)))초 전 동기화")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.leading, 12)
        }
    }

    @ViewBuilder
    private var currentBlock: some View {
        if let current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: current.kind.symbolName)
                    Text(current.kind.label)
                    if let person = current.person { Text("· \(person)") }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))

                Text(current.title)
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(3)

                HStack(spacing: 14) {
                    if let key = current.key {
                        Text(key)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    elapsedLabel(for: current)
                }

                if let notes = current.notes {
                    Text(notes).font(.footnote).foregroundStyle(.white.opacity(0.65))
                }
            }
        } else {
            Text("순서가 없습니다").font(.title3).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Elapsed against planned, so overrunning is visible while it is still
    /// worth doing something about.
    private func elapsedLabel(for item: PlanItem) -> some View {
        let elapsed = Int(now.timeIntervalSince(startedAt))
        let over = item.minutes.map { elapsed > $0 * 60 } ?? false
        return HStack(spacing: 5) {
            Image(systemName: "timer").font(.caption)
            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                .monospacedDigit()
            if let minutes = item.minutes {
                Text("/ \(minutes)분").foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.subheadline)
        .foregroundStyle(over ? Color.orange : .white.opacity(0.8))
    }

    @ViewBuilder
    private var nextBlock: some View {
        if let next {
            VStack(alignment: .leading, spacing: 4) {
                Text("다음").font(.caption).foregroundStyle(.white.opacity(0.45))
                HStack(spacing: 8) {
                    Image(systemName: next.kind.symbolName).font(.footnote)
                    Text(next.title).font(.title3).lineLimit(2)
                    if let key = next.key {
                        Text(key).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.bottom, 18)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { move(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 52)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled((currentIndex ?? 0) == 0)

            Button { move(by: 1) } label: {
                Label("다음 순서", systemImage: "chevron.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(next == nil)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    // MARK: - Sync

    /// Four seconds: fast enough that a follower is not visibly behind, slow
    /// enough that a team of ten stays far inside the per-user read quota.
    private func startPolling() async {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                if let sheetId = TeamSheetSource.current {
                    await team.pollLive(sheetId: sheetId)
                    lastHeard = Date()
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func move(by delta: Int) {
        guard let index = currentIndex else { return }
        let target = index + delta
        guard items.indices.contains(target), let sheetId = TeamSheetSource.current else { return }
        startedAt = Date()
        Task {
            await team.setLive(
                order: items[target].order,
                service: service,
                by: auth.displayName ?? auth.email ?? "",
                sheetId: sheetId
            )
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f
    }()
}
