import Foundation

/// Writes timestamped debug lines to ~/.claude-monitor/debug.log
/// Automatically rotates when the file exceeds 1 MB.
///
/// `@unchecked Sendable`: all mutable file/rotation state (`fileHandle`, and
/// the byte-count check in `rotateIfNeeded`) is only ever touched from the
/// private serial `queue`, which is the sole writer. `echoToStdout` is set
/// once at process startup (see `HeadlessRunner`) before any concurrent
/// logging begins, and after that is read-only from `log(_:category:level:)`.
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    /// When true (headless mode), every line is also printed to stdout so
    /// journald/docker logs capture it alongside the debug.log file.
    var echoToStdout = false

    private let queue = DispatchQueue(label: "com.claude-monitor.file-logger")
    private let maxBytes: UInt64 = 1_048_576 // 1 MB
    private let logDir: String
    private let logPath: String
    private var fileHandle: FileHandle?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        logDir = "\(home)/.claude-monitor"
        logPath = "\(logDir)/debug.log"
        openFile()
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public API

    func log(_ message: String, category: String = "App", level: Level = .info) {
        let ts = Self.formatter.string(from: Date())
        let line = "\(ts) [\(level.rawValue)] [\(category)] \(message)\n"
        if echoToStdout {
            print(line, terminator: "")
            // Flush every open output stream rather than naming `stdout`
            // directly: Linux's Glibc overlay (unlike Darwin's) doesn't mark
            // that C global Sendable, so referencing it at all is flagged
            // under Swift 6 mode. `fflush(nil)` is the portable equivalent
            // for the "make sure this just-printed line reaches
            // journald/docker logs immediately" intent here.
            fflush(nil)
        }
        queue.async { [weak self] in
            self?.writeLine(line)
        }
    }

    func info(_ message: String, category: String = "App") {
        log(message, category: category, level: .info)
    }

    func warning(_ message: String, category: String = "App") {
        log(message, category: category, level: .warn)
    }

    func error(_ message: String, category: String = "App") {
        log(message, category: category, level: .error)
    }

    /// Blocks until every write enqueued before this call has been written to
    /// disk. Writes happen on the private serial `queue`, so a no-op task
    /// submitted to that same queue only returns once everything ahead of it
    /// has run.
    ///
    /// Test-only synchronization seam (see `SelfTest.testCodexSnapshotOfflinePathWritesNoLog`,
    /// #116): proves a code path enqueued *no* write by flushing, then
    /// comparing file size, without racing the background queue or padding
    /// the user's real `debug.log` with a marker line just to observe it.
    func sync() {
        queue.sync {}
    }

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    // MARK: - Internal

    private func openFile() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.seekToEndOfFile()
    }

    private func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        fileHandle?.write(data)
    }

    private func rotateIfNeeded() {
        guard let handle = fileHandle else { return }
        let size = handle.offsetInFile
        guard size > maxBytes else { return }

        handle.closeFile()
        let backup = logPath + ".1"
        let fm = FileManager.default
        try? fm.removeItem(atPath: backup)
        try? fm.moveItem(atPath: logPath, toPath: backup)
        fm.createFile(atPath: logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: logPath)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
