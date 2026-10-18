import AppKit

enum Util {
    /// Runs a command off the main thread and hands stdout back on main.
    static func run(_ path: String, _ args: [String], completion: @escaping @MainActor (Data) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var data = Data()
            do {
                try p.run()
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            } catch {
                NSLog("FastGlance: \(path) failed: \(error)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(data) } }
        }
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "Never connected" }
        if Date().timeIntervalSince(date) < 60 { return "Last seen just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last seen " + f.localizedString(for: date, relativeTo: Date())
    }
}
