// swift-tools-version: 6.0
import PackageDescription

// The retry engine and the `codex-whip` command. The app bundles the same executable
// as Contents/Helpers/whip-helper; scripts/build_app.py builds it for both architectures.
let package = Package(
    name: "CodexWhip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "codex-whip", targets: ["codex-whip"]),
        .library(name: "WhipEngine", targets: ["WhipEngine"]),
    ],
    targets: [
        .target(name: "WhipEngine", resources: [.copy("Resources/whip.wav")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "codex-whip", dependencies: ["WhipEngine"]),
        .testTarget(name: "WhipEngineTests", dependencies: ["WhipEngine"]),
    ],
    swiftLanguageModes: [.v5]
)
