//
//  ContiFolder.swift
//  SolaPraise
//
//  The church's 콘티 folder — in its Shared Drive, readable by link — as the
//  source of each service's 콘티: every version, newest first.
//
//  WHY: the team keeps its 콘티 PDFs there, named by the service's date —
//  「20261011 주일예배 찬양.pdf」, 「20260913 주일예배 찬양 v2.pdf」 — owned by
//  the church rather than by whoever made them. Uploading each again
//  through the app made a second copy in someone's own Drive. The app now
//  reads the folder: a file is put there once, in Drive, and every member's
//  예배 준비 shows it under its service.
//
//  Read without signing in: through the Drive API with the app's key when
//  the key allows Drive, otherwise from the folder's public listing page.
//  The app does not write here — its Drive permission (drive.file) reaches
//  only files the app made.
//
//  The folder is set in the gitignored config (CONTI_FOLDER_ID) or pasted
//  in Settings; the repository is public and names no folder.
//

import Foundation

enum ContiFolder {

    struct File: Equatable {
        let id: String
        let name: String
        /// When it was last changed in Drive, for telling which is newer:
        /// this 콘티, or a song's chart attached since.
        var modified: Date? = nil

        /// The service day the name gives: 「20261011」, 「2026-10-11」,
        /// 「2026.10.11」.
        var date: Date? { ContiFolder.date(in: name) }
        /// 「v2」 → 2; a name with no version is version 1.
        var version: Int { ContiFolder.version(in: name) }
        var url: URL { URL(string: "https://drive.google.com/file/d/\(id)/view")! }
    }

    // MARK: - Where it is

    static var folderId: String? {
        if let typed = UserDefaults.standard.string(forKey: "conti.folderId"), !typed.isEmpty { return typed }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ContiFolderId") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    static var folderURL: URL? {
        folderId.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
    }

    /// A folder id out of whatever was pasted: a share link or the id.
    static func folderId(fromLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"folders/([A-Za-z0-9_-]{10,})"#, options: .regularExpression) {
            return String(trimmed[range].dropFirst("folders/".count))
        }
        return trimmed.range(of: #"^[A-Za-z0-9_-]{10,}$"#, options: .regularExpression) != nil ? trimmed : nil
    }

    // MARK: - Names

    static func date(in name: String) -> Date? {
        let patterns = [#"(20\d{2})(\d{2})(\d{2})"#, #"(20\d{2})[-.\s/](\d{1,2})[-.\s/](\d{1,2})"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  match.numberOfRanges == 4 else { continue }
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: name).flatMap { Int(name[$0]) } }
            guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { continue }
            var components = DateComponents()
            components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
            return Calendar.current.date(from: components)
        }
        return nil
    }

    static func version(in name: String) -> Int {
        let stem = (name as NSString).deletingPathExtension
        guard let range = stem.range(of: #"(?i)(?:^|[\s_\-(])v(?:er)?\.?\s*(\d{1,2})(?:\)|$|\s)"#, options: .regularExpression),
              let number = stem[range].split(whereSeparator: { !$0.isNumber }).last.flatMap({ Int($0) })
        else { return 1 }
        return number
    }

    /// One service's 콘티 files, newest version first.
    static func versions(for day: Date, in files: [File]) -> [File] {
        files.filter { $0.date.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { $0.version != $1.version ? $0.version > $1.version : $0.name > $1.name }
    }

    // MARK: - Reading the folder

    /// The folder's PDFs and images, or nil when it cannot be read.
    static func list(folderId: String, apiKey: String?) async -> [File]? {
        if let apiKey, let files = await listByAPI(folderId: folderId, apiKey: apiKey) { return files }
        return await listByPage(folderId: folderId)
    }

    private static func listByAPI(folderId: String, apiKey: String) async -> [File]? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: "'\(folderId)' in parents and trashed = false"),
            .init(name: "fields", value: "files(id,name,mimeType,modifiedTime)"),
            .init(name: "pageSize", value: "200"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "includeItemsFromAllDrives", value: "true"),
            .init(name: "key", value: apiKey)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        // The key is restricted to this app; Google checks it by this header.
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct List: Decodable {
            struct F: Decodable { let id: String; let name: String; let mimeType: String; let modifiedTime: String? }
            let files: [F]
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (try? JSONDecoder().decode(List.self, from: data))?.files
            .filter { $0.mimeType == "application/pdf" || $0.mimeType.hasPrefix("image/") }
            .map { File(id: $0.id, name: $0.name, modified: $0.modifiedTime.flatMap(iso.date(from:))) }
    }

    private static func listByPage(folderId: String) async -> [File]? {
        guard let url = URL(string: "https://drive.google.com/embeddedfolderview?id=\(folderId)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return parseFolderPage(html)
    }

    /// One entry of Drive's public folder listing page, of any kind.
    struct Entry: Equatable {
        let id: String
        let name: String
        /// Where the entry opens — a Doc, a Sheet or a file — which says
        /// what kind it is.
        let link: String?
        let modified: Date?
    }

    /// Every entry of Drive's public folder listing page.
    static func entries(inFolderPage html: String) -> [Entry] {
        guard let regex = try? NSRegularExpression(
            pattern: #"id="entry-([A-Za-z0-9_-]+)"(?:(?:(?!id="entry-).)*?href="([^"]*)")?(?:(?!id="entry-).)*?class="flip-entry-title">(.*?)</div>(?:(?:(?!id="entry-).)*?flip-entry-last-modified"><div>([^<]*))?"#,
            options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let id = Range(match.range(at: 1), in: html), let name = Range(match.range(at: 3), in: html) else { return nil }
            let link = Range(match.range(at: 2), in: html).map { String(html[$0]) }
            let modified = Range(match.range(at: 4), in: html).flatMap { listingDate(String(html[$0])) }
            let title = String(html[name])
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
            return Entry(id: String(html[id]), name: title, link: link, modified: modified)
        }
    }

    /// The PDFs and images of Drive's public folder listing page.
    static func parseFolderPage(_ html: String) -> [File] {
        entries(inFolderPage: html).compactMap { entry in
            let lower = entry.name.lowercased()
            guard lower.hasSuffix(".pdf") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
                    || lower.hasSuffix(".png") || lower.hasSuffix(".heic") else { return nil }
            return File(id: entry.id, name: entry.name, modified: entry.modified)
        }
    }

    /// The listing's 「Oct 10」, or 「10:35 PM」 for today; a date never in
    /// the future, so a December file seen in January is last year's.
    static func listingDate(_ text: String, now: Date = Date()) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "h:mm a"
        if let time = format.date(from: trimmed) {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            return Calendar.current.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now)
        }
        for pattern in ["MMM d, yyyy", "MMM d"] {
            format.dateFormat = pattern
            guard let day = format.date(from: trimmed) else { continue }
            var parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            if pattern == "MMM d" {
                parts.year = Calendar.current.component(.year, from: now)
                if let date = Calendar.current.date(from: parts), date > now { parts.year! -= 1 }
            }
            return Calendar.current.date(from: parts)
        }
        return nil
    }
}
