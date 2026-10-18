//
//  OfferingSheet.swift
//  SolaPraise
//
//  헌금송으로 지정: who prays the offering prayer, and the call that goes on
//  the chart with them — written to the song's notes on the team's sheet.
//

import SwiftUI

struct OfferingSheet: View {
    let song: String
    /// Who prays, as the notes say now.
    let prayer: String?
    let isOffering: Bool
    let onSave: (_ prayer: String) async -> String?
    let onRemove: () async -> String?
    let onCancel: () -> Void

    @State private var name = ""
    @State private var working = false
    @State private var failure: String?
    @AppStorage(OfferingNote.callKey) private var call = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 홍길동 형제님", text: $name)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("헌금기도")
                } footer: {
                    Text("팀 시트의 이 곡 메모에 「헌금송 · 헌금기도: 이름」으로 적힙니다. 악보와 콘티 PDF에 함께 나옵니다.")
                }
                Section {
                    Text(OfferingNote.call)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("헌금 안내 (설정에서 바꿀 수 있습니다)")
                }
                if isOffering {
                    Section {
                        Button("헌금송 지정 해제", role: .destructive) {
                            Task { await run(onRemove) }
                        }
                    }
                }
                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.orange) }
                }
            }
            .disabled(working)
            .navigationTitle(PlanSongTitle.split(song).title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button(isOffering ? "저장" : "헌금송으로 지정") {
                            Task { await run { await onSave(name) } }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { name = prayer ?? "" }
    }

    private func run(_ action: () async -> String?) async {
        working = true
        failure = await action()
        working = false
    }
}
