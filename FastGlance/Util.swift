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

    /// Blocking; call off the main thread. Exit status plus stdout and stderr together, for tools whose errors matter.
    /// A `timeout` terminates the tool, for network commands that can hang on an unreachable host.
    nonisolated static func exec(_ path: String, _ args: [String], timeout: TimeInterval? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
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
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false  // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: Int64(n))
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "Not seen connected yet" }
        if Date().timeIntervalSince(date) < 60 { return "Last seen just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last seen " + f.localizedString(for: date, relativeTo: Date())
    }
}
