// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SnapLex",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SnapLex", targets: ["SnapLex"])
    ],
    targets: [
        .executableTarget(
            name: "SnapLex",
            path: "Sources/SnapLex",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
