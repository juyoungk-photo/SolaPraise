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

    /// Several at once: a song often has a chart, a lead sheet and a
    /// lyric page, and a 콘티 is a stack of photos.
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var isUploading = false
    @State private var note: String?
    @State private var stand: ScoreStandItem?
    @State private var assigning: Attachment?

    private var existing: [Attachment] {
        // The service's own: 콘티 files uploaded whole. The app's built 콘티
        // PDF has its own button and is not listed twice.
        song.isEmpty ? team.attachments(for: service).filter { $0.belongsToService && !ContiPages.isBuilt($0) }
                     : team.attachments(for: service, song: song)
    }

    /// This song's pages of a 콘티 file uploaded whole, as worked out.
    private var contiPages: [(file: Attachment, pages: [Int])] {
        guard !song.isEmpty else { return [] }
        return team.attachments(for: service)
            .filter { $0.belongsToService && !ContiPages.isBuilt($0) }
            .compactMap { file in
                let pages = ContiPages.pages(of: file.fileId, for: song)
                return pages.isEmpty ? nil : (file, pages)
            }
    }

    var body: some View {
        Menu {
            if !contiPages.isEmpty {
                Section("콘티 파일에서") {
                    ForEach(contiPages, id: \.file.id) { entry in
                        Button {
                            stand = ScoreStandItem(attachment: entry.file, song: song,
                                                   teamKey: team.plan(for: service).first { $0.title == song }?.key,
                                                   pages: entry.pages)
                        } label: {
                            Label("\(pageLabel(entry.pages)) · \(entry.file.name)", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            // A 콘티 file: which page is which song, by hand.
            if song.isEmpty, !existing.isEmpty {
                Section {
                    ForEach(existing) { file in
                        Button { assigning = file } label: {
                            Label("곡별 페이지 지정 · \(file.name)", systemImage: "rectangle.split.3x1")
                        }
                    }
                }
            }
            if !existing.isEmpty {
                Section("첨부된 파일") {
                    ForEach(existing) { item in
                        // On the stand: a song's chart in the team's key, a
                        // whole 콘티 as it was made.
                        Button {
                            stand = standItem(item)
                        } label: {
                            Label(item.name, systemImage: item.belongsToService
                                  ? "doc" : "music.note.list")
                        }
                    }
                    ForEach(existing) { item in
                        Button { openURL(item.url) } label: {
                            Label("\(item.name) 원본 링크", systemImage: "arrow.up.right.square")
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
        .photosPicker(isPresented: $showPhotos, selection: $photos,
                      matching: .any(of: [.images]))
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { for url in urls { await upload(from: url) } }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items { await upload(from: item) }
                photos = []
            }
        }
        .sheet(item: $assigning) { file in
            ContiPagesSheet(attachment: file,
                            songs: team.plan(for: service).filter { $0.kind == .song }.map(\.title))
                .environmentObject(team)
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
        guard !song.isEmpty else {
            return ScoreStandItem(attachment: item, song: (item.name as NSString).deletingPathExtension, teamKey: nil)
        }
        return ScoreStandItem(attachment: item, song: song,
                              teamKey: team.plan(for: service).first { $0.title == song }?.key)
    }

    private var canUpload: Bool { team.canAttach && sheetId != nil }

    /// A transposed chart becomes another attachment on the same song, so
    /// the team sees the version in their key without each person making
    /// it again.
    private func sendTransposed(_ item: ScoreStandItem, data: Data, name: String) async -> String? {
        guard let sheetId else { return "시트가 연결되어 있지 않습니다." }
        let who = team.actingEmail(auth: auth, planning: planning) ?? ""
        // The same song in the same key, sent again, replaces the last one.
        return await team.attach(data: data, name: name, mimeType: "application/pdf",
                                 song: song, to: service, sheetId: sheetId, by: who,
                                 replacingSameName: true)
    }

    // MARK: - Uploading

    private func upload(from item: PhotosPickerItem) async {
        // Photos come as they were taken — usually HEIC — and went up as
        // that under a .jpg name, which a teammate's browser or Android
        // phone then could not show. Sent as a real JPEG, at most 3000 px
        // on its long side: a chart, not a print.
        guard let original = try? await item.loadTransferable(type: Data.self),
              let data = Self.chartJPEG(original) else {
            addNote("사진을 읽지 못했습니다.")
            return
        }
        // Unique even for several picked in the same second.
        let name = "\(stem)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).jpg"
        await send(data: data, name: name, mime: "image/jpeg")
    }

    private func upload(from url: URL) async {
        // A file chosen through the browser is outside the sandbox until
        // asked for; without this the read fails with a permission error
        // that reads like the file being missing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard var data = try? Data(contentsOf: url) else {
            addNote("파일을 읽지 못했습니다.")
            return
        }
        var uploadName = url.lastPathComponent
        // A photo from Files is a photo all the same: HEIC becomes JPEG.
        if url.pathExtension.lowercased() != "pdf", let jpeg = Self.chartJPEG(data) {
            data = jpeg
            uploadName = (uploadName as NSString).deletingPathExtension + ".jpg"
        }
        let mime = url.pathExtension.lowercased() == "pdf"
            ? "application/pdf"
            : (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
               ?? "application/octet-stream")
        await send(data: data, name: uploadName, mime: url.pathExtension.lowercased() == "pdf" ? mime : "image/jpeg")
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
            addNote(failure)
            return
        }
        // A 콘티 file is split onto the 순서 straight away, so each song's
        // clip shows its pages without anyone opening the stand first.
        if song.isEmpty {
            let songs = team.plan(for: service).filter { $0.kind == .song }.map(\.title)
            for file in team.attachments(for: service)
            where file.belongsToService && file.name == name && !ContiPages.isBuilt(file)
                && ContiPages.cached(file.fileId) == nil {
                ScoreFileCache.save(data, for: file.fileId)
                await ContiPages.compute(for: file, songs: songs)
            }
        }
    }

    /// Several files go up one after another; each one's message is kept.
    private func addNote(_ text: String) {
        note = note.map { "\($0)\n\(text)" } ?? text
    }

    /// An image as a JPEG for the team, no larger than 3000 px long.
    static func chartJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let long = max(image.size.width * image.scale, image.size.height * image.scale)
        let factor = min(1, 3000 / max(long, 1))
        let size = CGSize(width: image.size.width * image.scale * factor,
                          height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: 0.88)
    }

    private func pageLabel(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "" }
        return first == last ? "\(first + 1)쪽" : "\(first + 1)–\(last + 1)쪽"
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
