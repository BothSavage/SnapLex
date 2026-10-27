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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "SnapLex",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
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
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "SnapLexTests",
            dependencies: ["SnapLex"],
            path: "Tests/SnapLexTests"
        )
    ]
)
