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
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
