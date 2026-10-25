//
//  AddPlanItemSheet.swift
//  SolaPraise
//
//  One more line in the order of service.
//
//  헌신 찬양 is offered by name at the top: it goes in most weeks, and the
//  same song for months — the last ones sung are there to pick, with their
//  video and key, and only who prays is asked. Its 악보 follow by
//  themselves: a song with no chart this week shows the one it was last
//  played from. The call said before it is the church's, set in 설정.
//
//  Not every week is the template. A 특별순서, a baptism, a longer 광고 —
//  the screen's answer to all of them used to be "add it on the sheet's Plan
//  tab", which is true, and useless on a phone in a sanctuary ten minutes
//  before the service.
//

import SwiftUI

struct AddPlanItemSheet: View {
    let service: TeamService
    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: PlanItem.Kind = .other
    @State private var minutes = ""
    @State private var isSaving = false
    /// Adding the 헌신 찬양: a song, with who prays.
    @State private var dedication = false
    @State private var prayer = ""
    /// The earlier 헌신찬양 picked: its video and key come with it.
    @State private var picked: PlanItem?

    private let kinds: [PlanItem.Kind] = [
        .other, .song, .prayer, .reading, .sermon, .announcement, .offering, .transition
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $dedication.animation()) {
                        Label("헌신 찬양", systemImage: "gift")
                    }
                } footer: {
                    Text("헌금 때 부르는 찬양입니다. 지난번 곡을 고르고 헌금기도자만 적으면 됩니다.")
                }
                if dedication {
                    dedicationSections
                } else {
                    plainSection
                }

                if let message = team.errorMessage {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("순서 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("추가") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents(dedication ? [.large] : [.medium, .large])
    }

    @ViewBuilder
    private var dedicationSections: some View {
        let recent = team.recentOfferingSongs(before: service.date)
        if !recent.isEmpty {
            Section("지난 헌신찬양") {
                ForEach(recent, id: \.item.id) { entry in
                    Button {
                        picked = entry.item
                        title = entry.item.title
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PlanSongTitle.split(entry.item.title).title).foregroundStyle(Color.primary)
                                Text(entry.date.formatted(.dateTime.month().day())
                                     + (entry.item.key.map { " · \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if picked?.id == entry.item.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        Section {
            TextField("곡 이름", text: $title)
                .onChange(of: title) { _, now in
                    if let picked, now != picked.title { self.picked = nil }
                }
            TextField("헌금기도자 (예: 홍길동 형제님)", text: $prayer)
        } footer: {
            Text("헌금 안내: \(OfferingNote.call)\n— 설정에서 바꿀 수 있습니다. 악보와 콘티 PDF에 헌금기도자와 함께 나옵니다.")
        }
    }

    private var plainSection: some View {
                Section {
                    TextField("순서 이름", text: $title)
                        .submitLabel(.done)
                    Picker("구분", selection: $kind) {
                        ForEach(kinds, id: \.self) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text("길이")
                        Spacer()
                        TextField("분", text: $minutes)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("분").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("맨 뒤에 추가됩니다. 추가한 뒤 끌어서 자리를 옮기세요.")
                }
    }

    private func save() async {
        guard let sheetId = TeamSheetSource.current else { return }
        isSaving = true
        defer { isSaving = false }
        let name = title.trimmingCharacters(in: .whitespaces)
        let ok = dedication
            ? await team.appendPlanItem(
                title: name, kind: .song, minutes: picked?.minutes,
                key: picked?.key, url: picked?.url,
                notes: OfferingNote.notes(isOffering: true, prayer: prayer, rest: nil, word: "헌신찬양"),
                to: service, sheetId: sheetId)
            : await team.appendPlanItem(
                title: name,
                kind: kind,
                minutes: Int(minutes.trimmingCharacters(in: .whitespaces)),
                to: service,
                sheetId: sheetId
            )
        if ok { dismiss() }
    }
}
