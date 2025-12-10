import Foundation
import AppKit

class ExtensionInstaller: ObservableObject {
    @Published var nativeHostInstalled = false
    @Published var extensionInstalled = false
    @Published var installationStatus: String = ""

    private let firefoxNativeHostDir: URL
    private let appSupportDir: URL
    private let nativeHostName = "claude_monitor"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        firefoxNativeHostDir = home
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts")
        appSupportDir = home.appendingPathComponent(".claude-monitor")

        checkInstallationStatus()
    }

    func checkInstallationStatus() {
        // Check if native host manifest exists
        let manifestPath = firefoxNativeHostDir.appendingPathComponent("\(nativeHostName).json")
        nativeHostInstalled = FileManager.default.fileExists(atPath: manifestPath.path)

        // Check if database exists (indicates extension has sent data)
        let dbPath = appSupportDir.appendingPathComponent("usage.db")
        extensionInstalled = FileManager.default.fileExists(atPath: dbPath.path)
    }

    func installNativeHost() -> Bool {
        do {
            // Create directories
            try FileManager.default.createDirectory(at: firefoxNativeHostDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

            // Find the native host script (bundled in app or in development location)
            guard let hostScriptPath = findNativeHostScript() else {
                installationStatus = "Native host script not found"
                return false
            }

            // Create the native messaging manifest
            let manifest: [String: Any] = [
                "name": nativeHostName,
                "description": "Claude Usage Monitor Native Host",
                "path": hostScriptPath,
                "type": "stdio",
                "allowed_extensions": ["claude-monitor@local"]
            ]

            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
            let manifestPath = firefoxNativeHostDir.appendingPathComponent("\(nativeHostName).json")
            try manifestData.write(to: manifestPath)

            // Make the host script executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: hostScriptPath
            )

            nativeHostInstalled = true
            installationStatus = "Native host installed successfully"
            return true

        } catch {
            installationStatus = "Installation failed: \(error.localizedDescription)"
            return false
        }
    }

    private func findNativeHostScript() -> String? {
        // First, check if we're in a bundle (distributed app)
        if let bundlePath = Bundle.main.path(forResource: "claude_monitor_host", ofType: "cjs") {
            return bundlePath
        }

        // Check common development locations
        let possiblePaths = [
            // Relative to app in development
            "../../../native-host/claude_monitor_host.cjs",
            "../../native-host/claude_monitor_host.cjs",
            // Absolute paths for development
            "/Users/rwalters/GitHub/claude-monitor/native-host/claude_monitor_host.cjs"
        ]

        let fm = FileManager.default

        // Try relative paths from current working directory
        for relativePath in possiblePaths {
            let url = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(relativePath)
            if fm.fileExists(atPath: url.path) {
                return url.standardized.path
            }
        }

        // Try the absolute path directly
        let absolutePath = "/Users/rwalters/GitHub/claude-monitor/native-host/claude_monitor_host.cjs"
        if fm.fileExists(atPath: absolutePath) {
            return absolutePath
        }

        return nil
    }

    func openExtensionInstallGuide() {
        // Open Firefox debugging page for temporary extension installation
        if URL(string: "about:debugging#/runtime/this-firefox") != nil {
            // Firefox doesn't handle about: URLs directly from NSWorkspace
            // Instead, open Firefox with command line argument
            let firefoxPaths = [
                "/Applications/Firefox.app",
                "/Applications/Firefox Developer Edition.app",
                "/Applications/Firefox Nightly.app"
            ]

            for firefoxPath in firefoxPaths {
                if FileManager.default.fileExists(atPath: firefoxPath) {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "\(firefoxPath)/Contents/MacOS/firefox")
                    task.arguments = ["about:debugging#/runtime/this-firefox"]
                    try? task.run()
                    return
                }
            }

            // Fallback: open generic Firefox URL
            if let firefoxUrl = URL(string: "https://addons.mozilla.org/firefox/") {
                NSWorkspace.shared.open(firefoxUrl)
            }
        }
    }

    func openExtensionDownload() {
        if let url = URL(string: "https://github.com/rjwalters/claude-monitor/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
