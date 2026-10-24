// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SnapLex",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "SnapLex", targets: ["SnapLex"])
    ],
    targets: [
        .executableTarget(
            name: "SnapLex",
            path: "Sources/SnapLex",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Translation"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "SnapLexTests",
            dependencies: ["SnapLex"],
            path: "Tests/SnapLexTests"
        )
    ]
)
