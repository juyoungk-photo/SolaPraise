//
//  Recordings.swift
//  SolaPraise
//
//  Line-in captures kept on the device.
//
//  This is the app's own input, not YouTube: a rehearsal through the board, a
//  service, an instrument. Keeping the file is what makes a second pass
//  possible — live detection gets exactly one attempt at a performance, while
//  a saved capture can be re-analysed after the fact, at full file speed, as
//  the detector improves.
//

import AVFoundation
import Foundation

enum Recordings {

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// Caf rather than wav: wav's 32-bit header caps at 4 GB, which a long
    /// service at 48 kHz float gets uncomfortably close to.
    static func newFileURL(title: String) -> URL {
        let stamp = ISO8601DateFormatter.filenameFormatter.string(from: Date())
        let safe = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let name = safe.isEmpty ? stamp : "\(safe) \(stamp)"
        return directory.appendingPathComponent("\(name).caf")
    }

    struct Item: Identifiable, Hashable {
        let url: URL
        let createdAt: Date
        let seconds: Double
        var id: URL { url }

        var title: String { url.deletingPathExtension().lastPathComponent }
        var durationLabel: String {
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    static func all() -> [Item] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "caf" }
            .compactMap { url -> Item? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                // Read the duration from the file itself rather than deriving
                // it from bytes: a recording stopped by a write failure has a
                // header that no longer matches its length.
                let seconds = (try? AVAudioFile(forReading: url))
                    .map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                return Item(
                    url: url,
                    createdAt: values?.creationDate ?? .distantPast,
                    seconds: seconds
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
    }
}

private extension ISO8601DateFormatter {
    static let filenameFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        f.timeZone = .current
        return f
    }()
}
