// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Rec", path: "Sources/Rec")
    ]
)
