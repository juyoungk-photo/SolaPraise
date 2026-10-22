//
//  DriveClient.swift
//  SolaPraise
//
//  Uploading 악보 — an image or a PDF — so the team can open it.
//
//  WHY DRIVE AND NOT THE SHEET: a spreadsheet cell holds text. An attachment
//  has to live somewhere a link can point at, and the team is already in
//  Google's world with an account each.
//
//  WHY drive.file WORKS HERE WHEN IT DID NOT FOR THE SHEET: that scope
//  covers only files the app itself created or that the user chose through
//  Google's picker. The planning sheet had been through neither — its URL
//  was pasted in — so every request 403'd. These files the app creates, so
//  it has access to them by definition. drive.file is also NOT a sensitive
//  scope, which means adding it does not change anything about the consent
//  screen's verification.
//
//  WHO CAN UPLOAD: whoever is preparing the service. drive.file is
//  per-user-per-app, so a file one member's app created is not writable by
//  another member's app — but it does not need to be. The sheet is the
//  index and Drive is only storage: every upload is shared by link, so
//  reading an attachment needs no Drive permission at all, not even an
//  account. Several people uploading simply means files in several Drives,
//  all linked from one 콘티.
//
//  WHERE THE FILES GO: into one folder, 「SolaPraise 악보」, which the app
//  creates the first time. Moving that folder into the church's Shared
//  drive, once and by hand, moves the archive there — and because the app
//  created the folder, drive.file still covers it after the move, so every
//  later upload lands in the Shared drive too. A file in a Shared drive
//  belongs to the church rather than to whoever uploaded it, which is the
//  point of archiving there. A Drive link survives the move.
//
//  The app cannot do the move itself, nor be pointed at an existing Shared
//  drive folder: drive.file only reaches what the app made or what the user
//  picked in Google's picker, and the picker has no native iOS form.
//

import Foundation

actor DriveClient {

    enum DriveError: LocalizedError {
        case http(Int, String?)
        case badResponse
        case linkSharingBlocked

        var errorDescription: String? {
            switch self {
            case .http(401, _):      return "구글 로그인이 만료되었습니다. 다시 로그인해 주세요."
            case .http(403, let m):  return m ?? "드라이브에 올릴 권한이 없습니다."
            case .http(let code, let m): return m ?? "드라이브 오류 (\(code))"
            case .badResponse:       return "드라이브 응답을 읽지 못했습니다."
            case .linkSharingBlocked:
                return "이 계정의 드라이브는 '링크가 있는 모든 사용자' 공유를 막고 있어, 팀원이 열 수 없는 파일이 됩니다. 올리지 않았습니다. 교회 Google Workspace 관리자에게 외부 링크 공유 허용을 요청하거나, 개인 계정으로 드라이브 권한을 연결하세요."
            }
        }
    }

    struct Uploaded {
        let fileId: String
        /// What goes in the sheet, and what a teammate taps.
        let link: URL
    }

    private let tokenProvider: () async throws -> String
    private let session = URLSession(configuration: .default)

    /// Where the folder's id is kept on this device.
    static let folderKey = "drive.scoreFolderId"
    static let folderName = "SolaPraise 악보"
    private var folderId: String?

    /// The folder in Drive's web UI, for Settings to link to.
    static var folderURL: URL? {
        UserDefaults.standard.string(forKey: folderKey)
            .flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
    }

    init(tokenProvider: @escaping () async throws -> String) {
        self.tokenProvider = tokenProvider
    }

    // MARK: - Upload

    /// Uploads bytes and returns a link anyone on the team can open.
    ///
    /// Multipart rather than resumable: 악보 are a page or two — a few
    /// hundred kilobytes — and resumable upload is three round trips and a
    /// session URL to manage for a file that fits in one request.
    /// - folder: a folder to put it in instead — the team's 콘티 folder.
    ///   Refused (no access) is thrown, for the caller to fall back.
    func upload(data: Data, name: String, mimeType: String, folder: String? = nil) async throws -> Uploaded {
        let boundary = "solapraise-\(UUID().uuidString)"
        var body = Data()

        // Into the 악보 folder when it can be had. A folder that cannot be
        // created is not a reason to refuse the upload: the file goes to
        // the Drive root, as it always used to.
        // A chart for one song goes to the team's chosen folder (MusicSheet)
        // when one was chosen and still takes it; else this account's own.
        if folder == nil, let chosen = MusicSheetFolder.id {
            do {
                return try await upload(data: data, name: name, mimeType: mimeType, folder: chosen)
            } catch DriveError.http(let code, _) where code == 403 || code == 404 {
                MusicSheetFolder.problem = true
            } catch {
                // Anything else — a shared drive that forbids sharing by
                // link, say — falls back to this account's own folder: the
                // chart is put up either way.
            }
        }
        let parent: String?
        if let folder { parent = folder } else { parent = try? await scoreFolder() }
        struct Metadata: Encodable { let name: String; let parents: [String]? }
        let metadata = try JSONEncoder().encode(
            Metadata(name: name, parents: parent.map { [$0] }))

        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadata)
        append("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var components = URLComponents(
            string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [
            .init(name: "uploadType", value: "multipart"),
            .init(name: "fields", value: "id,webViewLink"),
            // Harmless when the file lands in My Drive, and required if it
            // ever lands in a Shared Drive — cheaper to always send than to
            // find out from a 403 that it was needed.
            .init(name: "supportsAllDrives", value: "true")
        ]

        struct Created: Decodable { let id: String; let webViewLink: String? }
        let created: Created = try await send(
            url: components.url!,
            method: "POST",
            body: body,
            contentType: "multipart/related; boundary=\(boundary)"
        )

        // Readable by link, so a teammate opens it without being added to
        // anything and without signing in. These are 악보 for a Sunday
        // service, not private documents — and the alternative is granting
        // each member individually and maintaining that list forever.
        //
        // A church Workspace can forbid link sharing outside the domain,
        // and then this is refused AFTER the file exists. It used to leave
        // that file behind, unlinked from anything, and report a raw
        // permission error. Now the file is taken back out and the reason
        // is said in words the person can take to whoever runs the domain.
        do {
            try await shareByLink(fileId: created.id)
        } catch {
            try? await delete(fileId: created.id)
            throw DriveError.linkSharingBlocked
        }

        let link = created.webViewLink.flatMap(URL.init(string:))
            ?? URL(string: "https://drive.google.com/file/d/\(created.id)/view")!
        return Uploaded(fileId: created.id, link: link)
    }

    // MARK: - Folder

    /// The 악보 folder's id, created the first time it is needed.
    ///
    /// Checked before reuse rather than trusted: a folder somebody trashed,
    /// or one another account made, would otherwise swallow every upload
    /// with a 404 that reads like the file being the problem.
    func scoreFolder() async throws -> String {
        if let cached = folderId ?? UserDefaults.standard.string(forKey: Self.folderKey),
           await isUsableFolder(cached) {
            folderId = cached
            return cached
        }
        // The folder this account already has, made by the app on another
        // device. The id was remembered per device, so the iPad and the
        // phone of one account each made a 「SolaPraise 악보」 of their own.
        // drive.file sees what this app created, from any device.
        if let existing = await existingFolder() {
            folderId = existing
            UserDefaults.standard.set(existing, forKey: Self.folderKey)
            return existing
        }
        struct NewFolder: Encodable {
            let name: String
            let mimeType = "application/vnd.google-apps.folder"
        }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "fields", value: "id"),
            .init(name: "supportsAllDrives", value: "true")
        ]
        struct Created: Decodable { let id: String }
        let created: Created = try await send(
            url: components.url!, method: "POST",
            body: try JSONEncoder().encode(NewFolder(name: Self.folderName)),
            contentType: "application/json")
        folderId = created.id
        UserDefaults.standard.set(created.id, forKey: Self.folderKey)
        return created.id
    }

    /// The oldest 「SolaPraise 악보」 folder this app made for this account,
    /// in My Drive or moved into a Shared Drive.
    private func existingFolder() async -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: "name = '\(Self.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            .init(name: "fields", value: "files(id)"),
            .init(name: "orderBy", value: "createdTime"),
            .init(name: "pageSize", value: "1"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "includeItemsFromAllDrives", value: "true"),
            .init(name: "corpora", value: "allDrives")
        ]
        guard let url = components.url, let token = try? await tokenProvider() else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct List: Decodable { struct F: Decodable { let id: String }; let files: [F] }
        return (try? JSONDecoder().decode(List.self, from: data))?.files.first?.id
    }

    private func isUsableFolder(_ id: String) async -> Bool {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [
            .init(name: "fields", value: "id,trashed"),
            .init(name: "supportsAllDrives", value: "true")
        ]
        guard let token = try? await tokenProvider() else { return false }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        struct State: Decodable { let trashed: Bool? }
        return (try? JSONDecoder().decode(State.self, from: data))?.trashed != true
    }

    private func shareByLink(fileId: String) async throws {
        struct Permission: Encodable { let role = "reader"; let type = "anyone" }
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileId)/permissions")!
        components.queryItems = [.init(name: "supportsAllDrives", value: "true")]
        struct Ignored: Decodable { let id: String? }
        let _: Ignored = try await send(
            url: components.url!,
            method: "POST",
            body: try JSONEncoder().encode(Permission()),
            contentType: "application/json"
        )
    }

    /// Writes over a file the app put there, keeping its id and its link.
    /// Refused for another account's file — the drive.file grant reaches
    /// only what this account made — and then the caller makes its own.
    func overwrite(fileId: String, data: Data, mimeType: String) async throws {
        var components = URLComponents(
            string: "https://www.googleapis.com/upload/drive/v3/files/\(fileId)")!
        components.queryItems = [
            .init(name: "uploadType", value: "media"),
            .init(name: "fields", value: "id"),
            .init(name: "supportsAllDrives", value: "true")
        ]
        struct Updated: Decodable { let id: String }
        let _: Updated = try await send(url: components.url!, method: "PATCH", body: data, contentType: mimeType)
    }

    /// A folder's name, as Drive has it now — for saying which folder.
    func name(of folderId: String) async -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(folderId)")!
        components.queryItems = [.init(name: "fields", value: "name"), .init(name: "supportsAllDrives", value: "true")]
        var request = URLRequest(url: components.url!)
        guard let token = try? await tokenProvider() else { return nil }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Named: Decodable { let name: String }
        return (try? JSONDecoder().decode(Named.self, from: data))?.name
    }

    /// To the trash, where the owner can still restore it for thirty days.
    func trash(fileId: String) async throws {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        components.queryItems = [.init(name: "supportsAllDrives", value: "true"), .init(name: "fields", value: "id")]
        struct Updated: Decodable { let id: String }
        let _: Updated = try await send(url: components.url!, method: "PATCH",
                                        body: Data(#"{"trashed":true}"#.utf8), contentType: "application/json")
    }

    /// The ids of this app's files in this account whose name has `part` —
    /// drive.file lists only what the app made.
    func files(named part: String) async throws -> [String] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let escaped = part.replacingOccurrences(of: "'", with: "\\'")
        components.queryItems = [
            .init(name: "q", value: "name contains '\(escaped)' and trashed = false"),
            .init(name: "fields", value: "files(id)"),
            .init(name: "pageSize", value: "200"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "includeItemsFromAllDrives", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DriveError.badResponse }
        struct Listing: Decodable { struct File: Decodable { let id: String }; let files: [File]? }
        return (try JSONDecoder().decode(Listing.self, from: data).files ?? []).map(\.id)
    }

    /// Removes a file the app put there.
    func delete(fileId: String) async throws {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        components.queryItems = [.init(name: "supportsAllDrives", value: "true")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(try await tokenProvider())",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse }
        // 404 means it is already gone, which is the outcome asked for.
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw DriveError.http(http.statusCode, Self.message(from: data))
        }
    }

    // MARK: - Transport

    private func send<T: Decodable>(url: URL,
                                    method: String,
                                    body: Data,
                                    contentType: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokenProvider())",
                         forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw DriveError.http(http.statusCode, Self.message(from: data))
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw DriveError.badResponse
        }
        return decoded
    }

    /// Google puts the useful sentence in error.message; surfacing the raw
    /// JSON instead is how 보관함 once showed a wall of braces.
    private static func message(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
    }
}

// MARK: - Reading a file back

extension URL {
    /// The bytes behind a Drive link.
    ///
    /// A webViewLink points at Drive's viewer PAGE — fetching it returns
    /// HTML, so building a combined PDF from those links produced a document
    /// of error pages. The uc?export=download form returns the file itself,
    /// and works without a token because every attachment is shared by link.
    var directDownload: URL {
        guard host?.contains("drive.google.com") == true,
              let id = Self.driveFileId(in: absoluteString),
              let direct = URL(string: "https://drive.google.com/uc?export=download&id=\(id)")
        else { return self }
        return direct
    }

    private static func driveFileId(in text: String) -> String? {
        if let range = text.range(of: "/d/([A-Za-z0-9_-]+)", options: .regularExpression) {
            return String(text[range].dropFirst(3))
        }
        if let range = text.range(of: "[?&]id=([A-Za-z0-9_-]+)", options: .regularExpression) {
            return String(text[range].drop(while: { $0 != "=" }).dropFirst())
        }
        return nil
    }
}

/// The church shared drive's folder for charts, one per song — 「MusicSheet」
/// — chosen once on each device through Google's picker (PlanningAuth
/// .pickFolder). Kept by id, so renaming or moving it inside the shared
/// drive changes nothing. 콘티 files go to the 콘티 folder as before.
///
/// WHY: each member's uploads went to a folder in their own Drive, so the
/// team's charts were spread over everyone's Drive and owned by whoever
/// put them up. The member can put files in the shared drive; the app, on
/// the narrow drive.file grant, only into a folder chosen in the picker.
enum MusicSheetFolder {
    private static let idKey = "drive.musicSheetFolder"
    private static let nameKey = "drive.musicSheetFolderName"
    private static let problemKey = "drive.musicSheetFolderProblem"

    static var id: String? { UserDefaults.standard.string(forKey: idKey) }
    static var name: String? { UserDefaults.standard.string(forKey: nameKey) }

    /// An upload to it was refused: deleted, moved out of the shared drive,
    /// or no longer shared with this account. Said until chosen again.
    static var problem: Bool {
        get { UserDefaults.standard.bool(forKey: problemKey) }
        set { UserDefaults.standard.set(newValue, forKey: problemKey) }
    }

    static func choose(_ id: String?, name: String?) {
        UserDefaults.standard.set(id, forKey: idKey)
        UserDefaults.standard.set(name, forKey: nameKey)
        problem = false
    }

    static var url: URL? { id.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") } }
}
