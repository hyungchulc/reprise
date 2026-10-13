// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reprise",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reprise", targets: ["Reprise"]),
        .executable(name: "RepriseMCP", targets: ["RepriseMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(url: "https://github.com/skiptools/swift-sqlcipher.git", exact: "1.13.0")
    ],
    targets: [
        .target(name: "RepriseCore", dependencies: [.product(name: "SQLCipher", package: "swift-sqlcipher")]),
        .target(name: "RepriseMCPKit", dependencies: ["RepriseCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "Reprise", dependencies: ["RepriseCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "RepriseMCP", dependencies: ["RepriseMCPKit"]),
        .testTarget(name: "RepriseCoreTests", dependencies: ["RepriseCore", .product(name: "SQLCipher", package: "swift-sqlcipher")]),
        .testTarget(name: "RepriseMCPTests", dependencies: ["RepriseMCPKit"]),
        .testTarget(name: "RepriseAppTests", dependencies: ["Reprise"])
    ],
    swiftLanguageModes: [.v5]
)
