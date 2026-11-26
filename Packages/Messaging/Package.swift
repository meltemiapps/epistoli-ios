// swift-tools-version: 6.0
import PackageDescription

// Apple-only: conversations and messages in the SQLCipher database, sealing with SealedCrypto, and
// the transports (section 4: a loopback folder; section 5: CloudKit).
let package = Package(
    name: "Messaging",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Messaging", targets: ["Messaging"]),
    ],
    dependencies: [
        .package(path: "../EpistoliCore"),
        .package(path: "../SealedCrypto"),
        .package(path: "../SealedStorage"),
        .package(path: "../KeyExchange"),
        .package(path: "../../Vendor/GRDB.swift"),
    ],
    targets: [
        .target(name: "Messaging", dependencies: [
            "EpistoliCore", "SealedCrypto", "KeyExchange",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "MessagingTests", dependencies: [
            "Messaging", "SealedStorage", .product(name: "KeyExchangeTestSupport", package: "KeyExchange"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
