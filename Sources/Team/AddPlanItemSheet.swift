//
//  AddPlanItemSheet.swift
//  SolaPraise
//
//  One more line in the order of service.
//
//  Two songs go in most weeks and have shortcuts of their own in 순서 추가
//  및 조정, each with the last ones sung to pick — their video and key come
//  with them:
//
//  - 헌금 찬양, sung as the offering is taken: who prays is asked, and the
//    call said before it is the church's, set in 설정.
//  - 헌신 찬양, the response after the sermon — often the 콘티's last song;
//    the church sheet may already name it.
//
//  They are different songs; one was taken for the other once, and the
//  헌신 찬양 came out with an offering prayer.
//
//  On a sheet that keeps its 순서 as the Songs tab's 찬양 alone (no Plan
//  tab), a song is written there, as 콘티에 추가 writes one. Its 악보 follow
//  by themselves: a song with no chart this week shows the one it was last
//  played from.
//
//  Not every week is the template. A 특별순서, a baptism, a longer 광고 —
//  the screen's answer to all of them used to be "add it on the sheet's Plan
//  tab", which is true, and useless on a phone in a sanctuary ten minutes
//  before the service.
//

import SwiftUI

struct AddPlanItemSheet: View {
    enum Mode { case plain, offering, dedication }

    let service: TeamService
    var mode: Mode = .plain
    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: PlanItem.Kind = .other
    @State private var minutes = ""
    @State private var isSaving = false
    @State private var prayer = ""
    @State private var failure: String?
    /// The earlier song picked: its video and key come with it.
    @State private var picked: PlanItem?

    private let kinds: [PlanItem.Kind] = [
        .other, .song, .prayer, .reading, .sermon, .announcement, .offering, .transition
    ]

    private var isSong: Bool { mode != .plain }

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .plain: plainSection
                case .offering: songSections(recent: team.recentOfferingSongs(before: service.date), heading: "최근 헌금 찬양")
                case .dedication: songSections(recent: team.recentDedicationSongs(before: service.date), heading: "최근 헌신 찬양")
                }

                if let message = failure ?? team.errorMessage {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(mode == .offering ? "헌금 찬양" : mode == .dedication ? "헌신 찬양" : "순서 추가")
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
        .presentationDetents(isSong ? [.large] : [.medium, .large])
    }

    @ViewBuilder
    private func songSections(recent: [(item: PlanItem, date: Date)], heading: String) -> some View {
        if !recent.isEmpty {
            Section(heading) {
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
            if mode == .offering {
                TextField("헌금기도자 (예: 홍길동 형제님)", text: $prayer)
            }
        } footer: {
            if mode == .offering {
                Text("헌금 안내: \(OfferingNote.call)\n— 설정에서 바꿀 수 있습니다. 악보와 콘티 PDF에 헌금기도자와 함께 나옵니다.")
            } else {
                Text("설교 뒤 응답으로 부르는 찬양입니다. 맨 뒤에 추가되니, 끌어서 자리를 옮기세요.")
            }
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

    /// The song line's notes: the mark that says which song it is.
    private var songNotes: String? {
        switch mode {
        case .offering: return OfferingNote.notes(isOffering: true, prayer: prayer, rest: nil, word: "헌금찬양")
        case .dedication: return DedicationNote.marker
        case .plain: return nil
        }
    }

    private func save() async {
        guard let sheetId = TeamSheetSource.current else { return }
        isSaving = true
        defer { isSaving = false }
        let name = title.trimmingCharacters(in: .whitespaces)
        failure = nil
        // No Plan tab: the 순서 is the Songs tab's 찬양, and a song goes there.
        if (isSong || kind == .song), !team.hasPlanTab {
            let result = await team.appendSong(
                title: name, videoId: picked?.videoId, key: picked?.key, channel: nil,
                notes: songNotes, to: service, sheetId: sheetId)
            switch result {
            case .added: dismiss()
            case .alreadyThere: failure = "이 곡은 이미 이 예배에 있습니다."
            case .misplaced: failure = "시트의 다른 칸에 들어갔습니다 — 예배 준비에서 확인하세요."
            case .failed(let message): failure = message
            }
            return
        }
        let ok = isSong
            ? await team.appendPlanItem(
                title: name, kind: .song, minutes: picked?.minutes,
                key: picked?.key, url: picked?.url, notes: songNotes,
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
