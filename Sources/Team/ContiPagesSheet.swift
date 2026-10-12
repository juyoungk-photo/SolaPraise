//
//  ContiPagesSheet.swift
//  SolaPraise
//
//  곡별 페이지 지정: which page of a 콘티 file is which song, set by hand
//  where reading the titles got it wrong — and shared, so the team does it
//  once.
//

import SwiftUI
import PDFKit

struct ContiPagesSheet: View {
    let attachment: Attachment
    let songs: [String]

    @EnvironmentObject private var team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [UIImage] = []
    @State private var pages: [Int: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text("페이지를 읽는 중…").foregroundStyle(.secondary) }
                } else if thumbnails.isEmpty {
                    Text("파일을 열 수 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(thumbnails.indices, id: \.self) { index in
                    HStack(spacing: 14) {
                        Image(uiImage: thumbnails[index])
                            .resizable()
                            .scaledToFit()
                            .frame(width: 84, height: 112)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(index + 1)쪽").font(.caption).foregroundStyle(.secondary)
                            Menu {
                                Button("곡 아님") { pages[index] = "" }
                                ForEach(songs, id: \.self) { song in
                                    Button(song) { pages[index] = song }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(pages[index].flatMap { $0.isEmpty ? nil : $0 } ?? "곡 아님")
                                        .foregroundStyle(pages[index]?.isEmpty == false ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("곡별 페이지 지정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("저장") }
                    }
                    .disabled(loading || saving || thumbnails.isEmpty)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        defer { loading = false }
        let songTitles = songs
        pages = await ContiPages.compute(for: attachment, songs: songTitles) ?? [:]
        let data: Data?
        if let kept = ScoreFileCache.load(attachment.fileId) {
            data = kept
        } else {
            data = try? await URLSession.shared.data(from: attachment.url.directDownload).0
        }
        guard let data else { return }
        thumbnails = await Task.detached(priority: .userInitiated) {
            if let document = PDFDocument(data: data) {
                return (0..<document.pageCount).compactMap { index in
                    document.page(at: index)?.thumbnail(of: CGSize(width: 252, height: 336), for: .mediaBox)
                }
            }
            return UIImage(data: data).map { [$0] } ?? []
        }.value
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var all = [Int: String]()
        for index in thumbnails.indices { all[index] = pages[index] ?? "" }
        ContiPages.setManual(all, for: attachment.fileId, count: thumbnails.count)
        switch await team.sharePageAssignment(fileId: attachment.fileId, pages: all) {
        case .success:
            dismiss()
        case .failure(.noAccess):
            note = "이 기기에 저장했습니다. 팀과 공유하려면 드라이브 권한을 연결하세요."
        case .failure:
            note = "이 기기에 저장했습니다. 팀과 공유하지는 못했습니다 — 시트를 새로 고친 뒤 다시 저장해 보세요."
        }
    }
}
