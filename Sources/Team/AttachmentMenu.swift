//
//  AttachmentMenu.swift
//  SolaPraise
//
//  Attaching 악보 to a song, and opening what is already there.
//
//  The files arrive as whatever people happen to have: a photo of a chart
//  on a stand, a PDF from the publisher, a screenshot of a phone screen. So
//  both doors are offered — the photo library and the file browser — rather
//  than insisting on one and making somebody convert.
//
//  Uploading needs an account; opening does not. Every attachment is shared
//  by link, so a teammate taps and reads without signing in to anything.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// The generic is named Content, not Label: a generic parameter called
// Label shadows SwiftUI's own Label inside this type, and every
// Label(_:systemImage:) in the menu stopped resolving.
struct AttachmentMenu<Content: View>: View {
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var planning: PlanningAuth
    @Environment(\.openURL) private var openURL

    let service: TeamService
    /// Empty means the attachment belongs to the service rather than a song.
    let song: String
    let sheetId: String?
    @ViewBuilder var label: Content

    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var isUploading = false
    @State private var note: String?
    @State private var stand: ScoreStandItem?

    private var existing: [Attachment] {
        song.isEmpty ? team.attachments(for: service).filter(\.belongsToService)
                     : team.attachments(for: service, song: song)
    }

    var body: some View {
        Menu {
            if !existing.isEmpty {
                Section("첨부된 파일") {
                    ForEach(existing) { item in
                        // A song's chart opens on the stand, in the team's
                        // key. The service's combined PDF is a document to
                        // read, and opens as one.
                        Button {
                            if item.belongsToService { openURL(item.url) }
                            else { stand = standItem(item) }
                        } label: {
                            Label(item.name, systemImage: item.belongsToService
                                  ? "doc" : "music.note.list")
                        }
                    }
                    if !song.isEmpty {
                        ForEach(existing) { item in
                            Button { openURL(item.url) } label: {
                                Label("\(item.name) 원본 링크", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                }
                Section {
                    ForEach(existing) { item in
                        Button(role: .destructive) {
                            Task { await remove(item) }
                        } label: {
                            Label("\(item.name) 지우기", systemImage: "trash")
                        }
                    }
                }
            }

            Section {
                if team.canAttach {
                    // PhotosPicker cannot live inside a Menu, so the menu
                    // sets a flag and the picker is attached to the label.
                    Button { showPhotos = true } label: {
                        Label("사진에서 추가", systemImage: "photo")
                    }
                    Button { showFiles = true } label: {
                        Label("파일에서 추가", systemImage: "folder")
                    }
                } else {
                    // A PERMISSION, not an account.
                    //
                    // The first wording said "시트 계정 연결", which is wrong
                    // for the common case and confusing in every case: the
                    // reader is already signed in — possibly as the very
                    // account being asked for — and is being told to
                    // connect an account they are looking at the name of.
                    //
                    // What is actually missing is Drive permission, which
                    // Google will not grant in the same breath as YouTube.
                    // The same account is fine; it is one extra sign-in.
                    Button {
                        Task {
                            await planning.signIn()
                            team.configure(auth: auth, planning: planning)
                        }
                    } label: {
                        Label("구글 드라이브 권한 연결", systemImage: "externaldrive.badge.plus")
                    }
                    Text("악보를 올리려면 드라이브 권한이 필요합니다. 지금 쓰는 계정 그대로 한 번 더 로그인하면 됩니다 — 구글이 유튜브 권한과 드라이브 권한을 한 번에 주지 않습니다.")
                }
            }
        } label: {
            label
        }
        // Never disabled outright: opening an attachment needs no account
        // at all, so a member without the second grant must still be able
        // to tap through to what the team has put up.
        .disabled(isUploading || sheetId == nil)
        .photosPicker(isPresented: $showPhotos, selection: $photo,
                      matching: .any(of: [.images]))
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await upload(from: url) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await upload(from: item) }
        }
        .fullScreenCover(item: $stand) { item in
            ScoreStandView(items: [item],
                           uploadTransposed: canUpload ? { item, data, name in
                               await sendTransposed(item, data: data, name: name)
                           } : nil)
        }
        .alert("첨부", isPresented: .constant(note != nil)) {
            Button("확인") { note = nil }
        } message: {
            Text(note ?? "")
        }
    }

    // MARK: - Stand

    private func standItem(_ item: Attachment) -> ScoreStandItem {
        ScoreStandItem(attachment: item, song: song,
                       teamKey: team.plan(for: service).first { $0.title == song }?.key)
    }

    private var canUpload: Bool { team.canAttach && sheetId != nil }

    /// A transposed chart becomes another attachment on the same song, so
    /// the team sees the version in their key without each person making
    /// it again.
    private func sendTransposed(_ item: ScoreStandItem, data: Data, name: String) async -> String? {
        guard let sheetId else { return "시트가 연결되어 있지 않습니다." }
        let who = team.actingEmail(auth: auth, planning: planning) ?? ""
        return await team.attach(data: data, name: name, mimeType: "application/pdf",
                                 song: song, to: service, sheetId: sheetId, by: who)
    }

    // MARK: - Uploading

    private func upload(from item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            note = "사진을 읽지 못했습니다."
            return
        }
        let name = "\(stem)-\(Int(Date().timeIntervalSince1970)).jpg"
        await send(data: data, name: name, mime: "image/jpeg")
    }

    private func upload(from url: URL) async {
        // A file chosen through the browser is outside the sandbox until
        // asked for; without this the read fails with a permission error
        // that reads like the file being missing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            note = "파일을 읽지 못했습니다."
            return
        }
        let mime = url.pathExtension.lowercased() == "pdf"
            ? "application/pdf"
            : (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
               ?? "application/octet-stream")
        await send(data: data, name: url.lastPathComponent, mime: mime)
    }

    private func send(data: Data, name: String, mime: String) async {
        guard let sheetId else { return }
        isUploading = true
        defer { isUploading = false }
        let who = team.actingEmail(auth: auth, planning: planning) ?? ""
        if let failure = await team.attach(
            data: data, name: name, mimeType: mime,
            song: song, to: service, sheetId: sheetId, by: who
        ) {
            note = failure
        }
    }

    private func remove(_ item: Attachment) async {
        guard let sheetId else { return }
        if let failure = await team.removeAttachment(item, sheetId: sheetId) {
            note = failure
        }
    }

    /// A filename that says what it is when it lands in somebody's Drive.
    private var stem: String {
        let day = TeamSheet.dateFormatter.string(from: service.date)
        let title = song.isEmpty ? service.title : song
        return "\(day)-\(title)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }
}
