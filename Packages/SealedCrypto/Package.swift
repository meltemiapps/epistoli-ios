// swift-tools-version: 6.0
import PackageDescription

// Apple-only: links the GopenPGP xcframework built by scripts/build_gopenpgp.sh.
let package = Package(
    name: "SealedCrypto",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SealedCrypto", targets: ["SealedCrypto"]),
    ],
    targets: [
        .binaryTarget(name: "EpistoliPGP", path: "../../Vendor/EpistoliPGP.xcframework"),
        .target(name: "SealedCrypto", dependencies: ["EpistoliPGP"]),
        .testTarget(name: "SealedCryptoTests", dependencies: ["SealedCrypto"]),
    ],
    swiftLanguageModes: [.v6]
)
