import AppKit

enum Util {
    /// Runs a command off the main thread and hands stdout back on main.
    static func run(_ path: String, _ args: [String], completion: @escaping @MainActor (Data) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let data = output(path, args)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(data) } }
        }
    }

    /// Blocking; call off the main thread.
    nonisolated static func output(_ path: String, _ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        } catch {
            NSLog("FastGlance: \(path) failed: \(error)")
            return Data()
        }
    }

    nonisolated static func text(_ path: String, _ args: [String]) -> String {
        String(decoding: output(path, args), as: UTF8.self)
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
