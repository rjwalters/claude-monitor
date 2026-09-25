import Foundation

/// Where LLM Monitor keeps its data, and the one-time move from the pre-2.0
/// `~/.claude-monitor` name.
///
/// **`dataDirectory` is the only way any code in this package finds its data
/// directory.** It is a lazily-initialized static, so the first access, from
/// any entry point (GUI, headless loop, or a one-shot CLI), runs
/// `migrateLegacyDataDirectory` exactly once before anything opens a file.
/// That ordering is what keeps a caller from creating a fresh, empty
/// `~/.llm-monitor` beside the real data. It is also why migration must not log
/// through `FileLogger`: the logger's own path comes from here.
///
/// **`~/.claude-monitor` stays as a symlink to `~/.llm-monitor`.** It is an
/// external contract: loom-daemon reads `usage.db`, `ranking.json`, and
/// `accounts.env` from it (or `LOOM_CLAUDE_MONITOR_DIR`), and `accounts
/// push`/`pull` peers may still run a pre-rename build. The symlink is removed
/// only once every consumer reads the new path.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum AppPaths {
    static let directoryName = ".llm-monitor"
    static let legacyDirectoryName = ".claude-monitor"

    /// `~/.llm-monitor`, migrated from `~/.claude-monitor` on first access.
    static let dataDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let outcome = migrateLegacyDataDirectory(home: home)
        if case .conflict(let message) = outcome {
            FileHandle.standardError.write(Data("llm-monitor: \(message)\n".utf8))
        }
        return (home as NSString).appendingPathComponent(directoryName)
    }()

    /// A file inside the data directory, e.g. `path("usage.db")`.
    static func path(_ name: String) -> String {
        (dataDirectory as NSString).appendingPathComponent(name)
    }

    static var databasePath: String { path("usage.db") }

    /// An environment override, preferring `LLM_MONITOR_<name>` and falling
    /// back to the pre-rename `CLAUDE_MONITOR_<name>`, so existing unit files
    /// and shell profiles keep working. Empty values count as unset.
    static func environment(
        _ name: String, in env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for key in ["LLM_MONITOR_\(name)", "CLAUDE_MONITOR_\(name)"] {
            if let value = env[key], !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Migration

    enum MigrationOutcome: Equatable {
        /// `~/.claude-monitor` was a real directory; it was moved to
        /// `~/.llm-monitor` and replaced by a symlink.
        case moved
        /// Nothing to move; `~/.llm-monitor` exists (created if needed) and
        /// the compatibility symlink was created.
        case linked
        /// Already migrated: the symlink is in place.
        case alreadyMigrated
        /// Both names are real directories, or the legacy name is something
        /// this code did not create. Nothing was touched; `~/.llm-monitor` is
        /// used as-is.
        case conflict(String)
    }

    /// Move `<home>/.claude-monitor` to `<home>/.llm-monitor` and leave a
    /// symlink at the old name. Idempotent, and never deletes or merges: any
    /// state it does not recognize is reported as `.conflict` and left alone.
    /// `home` is a parameter so the self-test can drive every case in a
    /// scratch directory.
    @discardableResult
    static func migrateLegacyDataDirectory(home: String) -> MigrationOutcome {
        let fm = FileManager.default
        let newPath = (home as NSString).appendingPathComponent(directoryName)
        let legacyPath = (home as NSString).appendingPathComponent(legacyDirectoryName)

        let legacyIsLink = (try? fm.destinationOfSymbolicLink(atPath: legacyPath)) != nil
        var legacyIsDir: ObjCBool = false
        let legacyExists = !legacyIsLink && fm.fileExists(atPath: legacyPath, isDirectory: &legacyIsDir)
        var newIsDir: ObjCBool = false
        let newExists = fm.fileExists(atPath: newPath, isDirectory: &newIsDir)

        if legacyIsLink {
            if !newExists { try? fm.createDirectory(atPath: newPath, withIntermediateDirectories: true) }
            return .alreadyMigrated
        }

        if legacyExists {
            guard legacyIsDir.boolValue else {
                return .conflict("\(legacyPath) is not a directory; left untouched")
            }
            if newExists {
                return .conflict(
                    "both \(legacyPath) and \(newPath) exist as directories; using \(newPath) and "
                    + "leaving \(legacyPath) untouched (merge or remove it, then relaunch)")
            }
            do {
                // A rename within one filesystem: processes that already hold
                // files open (e.g. a still-running older build, or loom-daemon
                // reading usage.db) keep valid descriptors.
                try fm.moveItem(atPath: legacyPath, toPath: newPath)
            } catch {
                return .conflict("could not move \(legacyPath) to \(newPath): \(error.localizedDescription)")
            }
            try? fm.createSymbolicLink(atPath: legacyPath, withDestinationPath: directoryName)
            return .moved
        }

        if !newExists {
            try? fm.createDirectory(atPath: newPath, withIntermediateDirectories: true)
        }
        // Relative target, so the link survives a home directory that is
        // itself reached through a symlink or a different mount path.
        try? fm.createSymbolicLink(atPath: legacyPath, withDestinationPath: directoryName)
        return .linked
    }
}
