// swift-tools-version: 6.0
import PackageDescription

// Apple-only: GRDB with SQLCipher (Vendor/GRDB.swift, from scripts/vendor_grdb.sh), Keychain, Secure Enclave.
let package = Package(
    name: "SealedStorage",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SealedStorage", targets: ["SealedStorage"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/GRDB.swift"),
    ],
    targets: [
        .target(name: "SealedStorage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SealedStorageTests", dependencies: ["SealedStorage"]),
    ],
    swiftLanguageModes: [.v6]
)
