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
//  A Shared Drive is not required. If the team would rather everything sat
//  in one place, the files can be moved there afterwards by hand — a Drive
//  link survives the move.
//

import Foundation

actor DriveClient {

    enum DriveError: LocalizedError {
        case http(Int, String?)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(401, _):      return "구글 로그인이 만료되었습니다. 다시 로그인해 주세요."
            case .http(403, let m):  return m ?? "드라이브에 올릴 권한이 없습니다."
            case .http(let code, let m): return m ?? "드라이브 오류 (\(code))"
            case .badResponse:       return "드라이브 응답을 읽지 못했습니다."
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

    init(tokenProvider: @escaping () async throws -> String) {
        self.tokenProvider = tokenProvider
    }

    // MARK: - Upload

    /// Uploads bytes and returns a link anyone on the team can open.
    ///
    /// Multipart rather than resumable: 악보 are a page or two — a few
    /// hundred kilobytes — and resumable upload is three round trips and a
    /// session URL to manage for a file that fits in one request.
    func upload(data: Data, name: String, mimeType: String) async throws -> Uploaded {
        let boundary = "solapraise-\(UUID().uuidString)"
        var body = Data()

        struct Metadata: Encodable { let name: String }
        let metadata = try JSONEncoder().encode(Metadata(name: name))

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
        try await shareByLink(fileId: created.id)

        let link = created.webViewLink.flatMap(URL.init(string:))
            ?? URL(string: "https://drive.google.com/file/d/\(created.id)/view")!
        return Uploaded(fileId: created.id, link: link)
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
