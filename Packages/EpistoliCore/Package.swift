// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EpistoliCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EpistoliCore", targets: ["EpistoliCore"]),
    ],
    targets: [
        .target(name: "EpistoliCore"),
        .testTarget(name: "EpistoliCoreTests", dependencies: ["EpistoliCore"]),
    ],
    swiftLanguageModes: [.v6]
)
