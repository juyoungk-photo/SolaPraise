//
//  LocalScores.swift
//  SolaPraise
//
//  작업실's 악보: charts brought in from Files or Photos and kept on this
//  device — for anyone, signed in or not, on a team or not.
//
//  WHY: reading a chart's chords, transposing it and printing it in the new
//  key lived only in 예배 준비, behind a team sheet and a sign-in. Someone
//  who installs the app to play from a chart had none of it. Here the same
//  stand (ScoreStandView) opens a file this device holds; nothing is
//  uploaded, nothing asks for an account.
//
//  Files live in Documents/Scores with a small index (index.json) holding
//  each chart's title and the order — the order is the set the stand plays
//  through, and what 「전체」 exports as one PDF.
//

import Foundation
import UIKit

@MainActor
final class LocalScores: ObservableObject {

    struct Item: Codable, Identifiable, Hashable {
        let id: UUID
        /// The file name in the Scores folder.
        let file: String
        var title: String
        let addedAt: Date
    }

    @Published private(set) var items: [Item] = []

    static let shared = LocalScores()

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    init(folder: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? documents.appendingPathComponent("Scores", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        load()
    }

    func url(for item: Item) -> URL { folder.appendingPathComponent(item.file) }

    /// The stand's view of a chart. The id is stable across launches, so
    /// the chords read, the corrections made and the key chosen stay with
    /// the chart (ScoreEditStore, ScoreKeyStore key on it).
    func standItem(for item: Item) -> ScoreStandItem {
        let attachment = Attachment(date: item.addedAt, song: item.title,
                                    name: item.title + "." + (item.file as NSString).pathExtension,
                                    fileId: "local-\(item.id.uuidString)", url: url(for: item), addedBy: "")
        return ScoreStandItem(attachment: attachment, song: item.title, teamKey: nil)
    }

    // MARK: - Bringing charts in

    /// A file picked in Files: a PDF as it is, a photo as a JPEG.
    @discardableResult
    func add(fileAt source: URL) -> Item? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else { return nil }
        let title = source.deletingPathExtension().lastPathComponent
        if source.pathExtension.lowercased() == "pdf" { return add(data: data, extension: "pdf", title: title) }
        guard let jpeg = Self.chartJPEG(data) else { return nil }
        return add(data: jpeg, extension: "jpg", title: title)
    }

    /// A photo: stored as a JPEG, whatever the camera wrote.
    @discardableResult
    func add(photo data: Data, title: String) -> Item? {
        guard let jpeg = Self.chartJPEG(data) else { return nil }
        return add(data: jpeg, extension: "jpg", title: title)
    }

    private func add(data: Data, extension ext: String, title: String) -> Item? {
        let id = UUID()
        let file = "\(id.uuidString).\(ext)"
        do { try data.write(to: folder.appendingPathComponent(file), options: .atomic) }
        catch { return nil }
        let item = Item(id: id, file: file, title: title, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    // MARK: - Changing the list

    func rename(_ item: Item, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].title = trimmed
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets where items.indices.contains(index) {
            try? FileManager.default.removeItem(at: url(for: items[index]))
        }
        items.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([Item].self, from: data) else { items = []; return }
        // A file removed behind the app's back is not offered.
        items = stored.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// A chart, not a print: at most 3000 px on the long side, as JPEG —
    /// the same as a chart attached in 예배 준비.
    static func chartJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let long = max(image.size.width * image.scale, image.size.height * image.scale)
        let factor = min(1, 3000 / max(long, 1))
        let size = CGSize(width: image.size.width * image.scale * factor,
                          height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.88)
    }
}
