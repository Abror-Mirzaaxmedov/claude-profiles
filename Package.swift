// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeProfiles", targets: ["ClaudeProfiles"])
    ],
    targets: [
        .executableTarget(name: "ClaudeProfiles")
    ]
)
