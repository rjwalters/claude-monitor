import Foundation
import AppKit

class ExtensionInstaller: ObservableObject {
    @Published var firefoxNativeHostInstalled = false
    @Published var chromeNativeHostInstalled = false
    @Published var nativeHostInstalled = false  // True if any browser installed
    @Published var extensionInstalled = false
    @Published var installationStatus: String = ""

    private let firefoxNativeHostDir: URL
    private let chromeNativeHostDir: URL
    private let appSupportDir: URL
    private let nativeHostName = "claude_monitor"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        firefoxNativeHostDir = home
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts")
        chromeNativeHostDir = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        appSupportDir = home.appendingPathComponent(".claude-monitor")

        checkInstallationStatus()
    }

    func checkInstallationStatus() {
        // Check if native host manifest exists for Firefox
        let firefoxManifestPath = firefoxNativeHostDir.appendingPathComponent("\(nativeHostName).json")
        firefoxNativeHostInstalled = FileManager.default.fileExists(atPath: firefoxManifestPath.path)

        // Check if native host manifest exists for Chrome
        let chromeManifestPath = chromeNativeHostDir.appendingPathComponent("\(nativeHostName).json")
        chromeNativeHostInstalled = FileManager.default.fileExists(atPath: chromeManifestPath.path)

        // Overall status - true if any browser has native host installed
        nativeHostInstalled = firefoxNativeHostInstalled || chromeNativeHostInstalled

        // Check if database exists (indicates extension has sent data)
        let dbPath = appSupportDir.appendingPathComponent("usage.db")
        extensionInstalled = FileManager.default.fileExists(atPath: dbPath.path)
    }

    func installNativeHost() -> Bool {
        // Install for both browsers
        let firefoxResult = installFirefoxNativeHost()
        let chromeResult = installChromeNativeHost()

        checkInstallationStatus()

        if firefoxResult && chromeResult {
            installationStatus = "Native host installed for Firefox and Chrome"
        } else if firefoxResult {
            installationStatus = "Native host installed for Firefox"
        } else if chromeResult {
            installationStatus = "Native host installed for Chrome"
        } else {
            installationStatus = "Failed to install native host"
        }

        return firefoxResult || chromeResult
    }

    func installFirefoxNativeHost() -> Bool {
        do {
            try FileManager.default.createDirectory(at: firefoxNativeHostDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

            guard let hostScriptPath = findNativeHostScript() else {
                return false
            }

            // Firefox uses allowed_extensions with extension ID
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

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostScriptPath)

            firefoxNativeHostInstalled = true
            return true

        } catch {
            return false
        }
    }

    func installChromeNativeHost(extensionId: String? = nil) -> Bool {
        do {
            try FileManager.default.createDirectory(at: chromeNativeHostDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

            guard let hostScriptPath = findNativeHostScript() else {
                return false
            }

            // Chrome uses allowed_origins with extension ID
            // The extension has a "key" in manifest.json that generates a stable ID
            // Extension ID: akhjonljkoklbpdobdnnobgbniehcimn (generated from key)
            let origins: [String]
            if let extId = extensionId, !extId.isEmpty {
                origins = ["chrome-extension://\(extId)/"]
            } else {
                // Default extension ID generated from our key in manifest.json
                origins = ["chrome-extension://akhjonljkoklbpdobdnnobgbniehcimn/"]
            }

            let manifest: [String: Any] = [
                "name": nativeHostName,
                "description": "Claude Usage Monitor Native Host",
                "path": hostScriptPath,
                "type": "stdio",
                "allowed_origins": origins
            ]

            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
            let manifestPath = chromeNativeHostDir.appendingPathComponent("\(nativeHostName).json")
            try manifestData.write(to: manifestPath)

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostScriptPath)

            chromeNativeHostInstalled = true
            return true

        } catch {
            return false
        }
    }

    private func findNativeHostScript() -> String? {
        // First, check if we're in a bundle (distributed app)
        if let bundlePath = Bundle.main.path(forResource: "claude_monitor_host", ofType: "cjs") {
            return bundlePath
        }

        // Check common development locations (relative to working directory)
        let possiblePaths = [
            "../../../native-host/claude_monitor_host.cjs",
            "../../native-host/claude_monitor_host.cjs",
            "../native-host/claude_monitor_host.cjs",
            "native-host/claude_monitor_host.cjs"
        ]

        let fm = FileManager.default

        // Try relative paths from current working directory
        for relativePath in possiblePaths {
            let url = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(relativePath)
            if fm.fileExists(atPath: url.path) {
                return url.standardized.path
            }
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
