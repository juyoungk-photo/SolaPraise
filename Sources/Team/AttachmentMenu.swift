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
    /// For finding a chart on the web from the list: the channel names the
    /// song's team, and its upload's own links come first.
    var channel: String? = nil
    var published: [SheetMusicLink] = []
    /// Where a chart found on the web goes. Nil hides 「웹에서 찾기」.
    var finds: ScoreDestination? = nil
    /// The 코드표 the app made by listening, when there is one.
    var appChart: (() -> Void)? = nil
    /// The song as the 헌금송, or not; nil where it cannot be marked here.
    var offering: OfferingNote.Parsed? = nil
    var onOffering: (() -> Void)? = nil
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
        // Newest first: a song collects versions of its chart.
        song.isEmpty ? team.attachments(for: service).filter { $0.belongsToService && !ContiPages.isBuilt($0) }.reversed()
                     : team.attachments(for: service, song: song).reversed()
    }

    /// This song's pages of the service's newest 콘티, as worked out.
    private var contiPages: [(file: Attachment, pages: [Int])] {
        guard !song.isEmpty, let latest = team.contis(for: service).first else { return [] }
        let pages = ContiPages.pages(of: latest.fileId, for: song)
        return pages.isEmpty ? [] : [(latest, pages)]
    }

    @State private var showsList = false
    @State private var memoText = ""
    @State private var memoSaving = false

    var body: some View {
        // A list, not a menu: each chart once — a tap opens it on the stand,
        // a swipe takes it off. The menu listed every chart three times
        // (open, its Drive link, delete), which read as three kinds of
        // thing; the link is now a button on the stand.
        Button { showsList = true } label: { label }
        .sheet(isPresented: $showsList) { listSheet }
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

    private var listSheet: some View {
        NavigationStack {
            List {
                if !contiPages.isEmpty {
                    Section("콘티에서 (최신)") {
                        ForEach(contiPages, id: \.file.id) { entry in
                            Button {
                                open(ScoreStandItem(attachment: entry.file, song: song,
                                                    teamKey: team.plan(for: service).first { PlanSongTitle.sameSong($0.title, song) }?.key,
                                                    pages: entry.pages))
                            } label: {
                                Label("\(pageLabel(entry.pages)) · \(entry.file.name)", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                if !existing.isEmpty {
                    Section(song.isEmpty ? "올린 콘티 파일" : "첨부한 악보 — 최신부터") {
                        ForEach(existing) { item in
                            Button { open(standItem(item)) } label: {
                                Label(item.name, systemImage: item.belongsToService ? "doc" : "music.note.list")
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await remove(item) }
                                } label: { Label("지우기", systemImage: "trash") }
                            }
                        }
                    }
                }
                // The team's memo for the song — kept by song on the sheet's
                // 곡 메모 tab, so it is there every time the song comes round.
                if !song.isEmpty {
                    Section {
                        TextField("인트로 4마디, 2절 후 간주 없이 …", text: $memoText, axis: .vertical)
                            .lineLimit(2...6)
                        Button {
                            Task { await saveMemo() }
                        } label: {
                            if memoSaving { ProgressView() } else { Text("메모 저장") }
                        }
                        .disabled(memoSaving || sheetId == nil || team.isReadOnly
                                  || memoText.trimmingCharacters(in: .whitespacesAndNewlines)
                                     == (team.memo(for: song)?.text ?? ""))
                    } header: {
                        Text("팀 메모")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("이 곡을 다시 부를 때마다 보입니다. 팀 시트의 「곡 메모」 탭에 곡별로 적혀, 시트에서 바로 고쳐도 됩니다." +
                                 (team.memo(for: song).map { $0.by.isEmpty ? "" : " 마지막으로 고친 사람: \($0.by)" } ?? ""))
                            // 지난 예배: what the team did with it before.
                            let history = team.history(for: song)
                            if !history.isEmpty {
                                Text("지난 예배").fontWeight(.semibold).padding(.top, 4)
                                ForEach(history.prefix(4), id: \.self) { Text($0) }
                            }
                        }
                    }
                }
                // What the song's chart carries besides: as the 헌금송, who
                // prays and the call (OfferingSheet).
                if let offering, let onOffering {
                    Section {
                        Button {
                            showsList = false
                            later(onOffering)
                        } label: {
                            Label(offering.isOffering
                                  ? "헌금송" + (offering.prayer.map { " · 헌금기도 \($0)" } ?? "") + " — 바꾸기"
                                  : "헌금송으로 지정",
                                  systemImage: "gift")
                        }
                    } footer: {
                        Text("헌금송은 악보와 콘티 PDF에 헌금기도자와 헌금 안내가 함께 나옵니다.")
                    }
                }
                if let appChart {
                    Section("앱이 소리로 만든 코드표") {
                        Button {
                            showsList = false
                            later(appChart)
                        } label: {
                            Label("코드표 열기", systemImage: "music.quarternote.3")
                        }
                    }
                }
                Section {
                    // Searching needs no account; what is found is kept in
                    // 작업실 when it cannot be attached.
                    if let finds {
                        NavigationLink {
                            List {
                                SheetMusicLinks(title: song, channel: channel, published: published,
                                                destination: finds)
                            }
                            .navigationTitle("웹에서 악보 찾기")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("웹에서 찾기", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    if team.canAttach {
                        Button {
                            showsList = false
                            later { showPhotos = true }
                        } label: { Label("사진에서 추가", systemImage: "photo") }
                        Button {
                            showsList = false
                            later { showFiles = true }
                        } label: { Label("파일에서 추가", systemImage: "folder") }
                    } else {
                        AccountSignInButton(role: .church) {
                            await planning.signIn()
                            team.configure(auth: auth, planning: planning)
                        }
                    }
                } footer: {
                    if !team.canAttach {
                        Text("악보는 교회 계정으로 팀 드라이브에 올립니다. YouTube 계정과 같은 계정이어도 한 번 더 연결해야 합니다 — 구글이 YouTube 권한과 드라이브 권한을 한 번에 주지 않습니다.")
                    } else if !existing.isEmpty {
                        Text("누르면 연주 모드로 열립니다. 왼쪽으로 밀면 지웁니다.")
                    }
                }
            }
            .navigationTitle(song.isEmpty ? "콘티 파일" : PlanSongTitle.split(song).title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { showsList = false } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { memoText = team.memo(for: song)?.text ?? "" }
    }

    private func saveMemo() async {
        guard let sheetId else { return }
        memoSaving = true
        defer { memoSaving = false }
        let who = team.rosterName(for: team.actingEmail(auth: auth, planning: planning) ?? "") ?? auth.displayName ?? ""
        let failure = await team.setMemo(memoText, for: song, by: who, sheetId: sheetId)
        if let failure { note = failure }
        Toast.shared.sheet(failure, saved: "팀 메모 — 시트에 저장됨")
    }

    /// From the list to the stand: the list goes, then the stand comes.
    private func open(_ item: ScoreStandItem) {
        showsList = false
        later { stand = item }
    }

    /// After the sheet has gone: one presentation at a time.
    private func later(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    // MARK: - Stand

    private func standItem(_ item: Attachment) -> ScoreStandItem {
        guard !song.isEmpty else {
            return ScoreStandItem(attachment: item, song: (item.name as NSString).deletingPathExtension, teamKey: nil)
        }
        return ScoreStandItem(attachment: item, song: song,
                              teamKey: team.plan(for: service).first { PlanSongTitle.sameSong($0.title, song) }?.key)
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
