import Foundation

/// Every device ever seen: name, type and when it was last connected.
struct DeviceHistory: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var id: String
        var name: String
        var kind: DeviceKind
        var lastConnected: Date?
        /// The user's own name and "hide from the menu". Optional so older history files still load.
        var nickname: String?
        var hidden: Bool?
    }

    var entries: [String: Entry] = [:]

    /// Merges live devices in. Returns true when an entry was added, renamed or retyped.
    @discardableResult
    mutating func record(_ devices: [Device], now: Date) -> Bool {
        var changed = false
        for d in devices {
            var e = entries[d.id] ?? Entry(id: d.id, name: d.name, kind: d.kind, lastConnected: nil)
            if entries[d.id] == nil || e.name != d.name || e.kind != d.kind { changed = true }
            e.name = d.name
            e.kind = d.kind
            if d.isConnected { e.lastConnected = now }
            entries[d.id] = e
        }
        return changed
    }

    /// Stamps devices that just went away, so "last seen" is the moment they disconnected.
    mutating func markDisconnected(_ ids: Set<String>, now: Date) {
        for id in ids { entries[id]?.lastConnected = now }
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    static func load(from url: URL = url) -> DeviceHistory {
        guard let data = try? Data(contentsOf: url) else { return DeviceHistory() }
        do {
            return try JSONDecoder.iso.decode(DeviceHistory.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it with an empty history.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("FastGlance: history unreadable, moved to \(backup.path): \(error)")
            return DeviceHistory()
        }
    }

    func save(to url: URL = url) {
        do {
            try JSONEncoder.iso.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("FastGlance: failed to save history: \(error)")
        }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
