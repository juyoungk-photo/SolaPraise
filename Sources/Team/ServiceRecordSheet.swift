//
//  ServiceRecordSheet.swift
//  SolaPraise
//
//  예배 기록: after the service, each song's key and the 순서's notes put
//  onto its 지난 예배 on the 곡 메모 tab — shown first, written on a press.
//
//  WHY: the Songs tab knows what was sung, but by Sunday, not by song.
//  「Last time we did this in A, intro 4 bars」 was there, spread over a
//  year of rows. On the song's own row it is read at a glance, in the app
//  (팀 메모) and on the sheet without it.
//

import SwiftUI

struct ServiceRecordSheet: View {
    let service: TeamService
    let sheetId: String?

    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(team.recordPreview(service).enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.song).font(.body)
                            Text(entry.line).font(.caption).foregroundStyle(.secondary)
                            if let before = team.history(for: entry.song)
                                .first(where: { !$0.hasPrefix(String(entry.line.prefix(10))) }) {
                                Text("그 전: " + before).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(service.date.formatted(.dateTime.month().day().weekday()) + " " + service.title)
                } footer: {
                    Text("곡마다 팀 시트 「곡 메모」 탭의 「지난 예배」 칸 맨 위에 한 줄씩 적습니다. 다른 칸은 건드리지 않고, 같은 날을 다시 기록하면 그 줄을 바꿉니다. 곡별로 최근 \(SongMemos.historyKept)번까지 남습니다.")
                }
                if let note {
                    Section { Text(note).foregroundStyle(.red) }
                }
            }
            .navigationTitle(team.isRecorded(service) ? "기록됨" : "예배 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(team.isRecorded(service) ? "다시 기록" : "곡 메모에 기록") {
                            Task { await record() }
                        }
                        .disabled(sheetId == nil || team.isReadOnly)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func record() async {
        guard let sheetId else { return }
        working = true
        defer { working = false }
        if let failure = await team.record(service, sheetId: sheetId) {
            note = failure
        } else {
            dismiss()
        }
    }
}
