// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaPer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "QuotaPer", path: "Sources/QuotaPer")
    ]
)
