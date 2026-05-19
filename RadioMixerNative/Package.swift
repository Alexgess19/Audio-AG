// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioAG",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AudioAG")
    ]
)
