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

    private var existing: [Attachment] {
        song.isEmpty ? team.attachments(for: service).filter(\.belongsToService)
                     : team.attachments(for: service, song: song)
    }

    var body: some View {
        Menu {
            if !existing.isEmpty {
                Section("첨부된 파일") {
                    ForEach(existing) { item in
                        Button { openURL(item.url) } label: {
                            Label(item.name, systemImage: "doc")
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
                    // Not a failure to hide. Google refuses youtube and
                    // drive.file in one grant, so uploading needs the sheet
                    // account connected — the same one a team using a
                    // church account for the sheet already connects.
                    Button {
                        Task {
                            await planning.signIn()
                            team.configure(auth: auth, planning: planning)
                        }
                    } label: {
                        Label("첨부하려면 시트 계정 연결", systemImage: "person.badge.key")
                    }
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
        .alert("첨부", isPresented: .constant(note != nil)) {
            Button("확인") { note = nil }
        } message: {
            Text(note ?? "")
        }
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
