// swift-tools-version: 6.0
import PackageDescription

// Apple-only: identity key storage (Keychain, Secure Enclave), contact codes, contacts in the SQLCipher database.
let package = Package(
    name: "KeyExchange",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "KeyExchange", targets: ["KeyExchange"]),
        // Test-only helpers (the private-key leak scanner). Never linked into the app itself.
        .library(name: "KeyExchangeTestSupport", targets: ["KeyExchangeTestSupport"]),
    ],
    dependencies: [
        .package(path: "../EpistoliCore"),
        .package(path: "../SealedCrypto"),
        .package(path: "../SealedStorage"),
        .package(path: "../../Vendor/GRDB.swift"),
    ],
    targets: [
        .target(name: "KeyExchange", dependencies: [
            "EpistoliCore", "SealedCrypto", "SealedStorage",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "KeyExchangeTestSupport", dependencies: [
            "SealedCrypto", .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "KeyExchangeTests", dependencies: ["KeyExchange", "KeyExchangeTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
