// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Linux has no SQLite3 SDK module; this system-library target maps the
        // distro's libsqlite3 (apt: libsqlite3-dev). macOS uses the SDK module.
        .systemLibrary(
            name: "CSQLite",
            path: "CSQLite",
            providers: [
                .apt(["libsqlite3-dev"]),
                .yum(["sqlite-devel"])
            ]
        ),
        .executableTarget(
            name: "ClaudeMonitor",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux]))
            ],
            path: "Sources",
            swiftSettings: [
                // `-swift-version 6` (rather than bumping this manifest's
                // `swift-tools-version` to 6.0 and using the
                // `.swiftLanguageMode(.v6)` API) keeps the manifest itself
                // parseable by any 5.9+ SwiftPM/toolchain — including
                // whatever exact Xcode CI's `macos-14` runner happens to
                // pin — while still forcing full Swift 6 language-mode
                // checking on every `swift build`, matching the local
                // `-Xswiftc -swift-version -Xswiftc 6` proxy this setting
                // retires (see CLAUDE.md).
                .unsafeFlags(["-parse-as-library", "-swift-version", "6"])
            ]
        )
    ]
)
