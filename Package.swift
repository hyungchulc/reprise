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
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "RepriseCore", dependencies: ["CSQLite"]),
        .target(name: "RepriseMCPKit", dependencies: ["RepriseCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "Reprise", dependencies: ["RepriseCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "RepriseMCP", dependencies: ["RepriseMCPKit"]),
        .testTarget(name: "RepriseCoreTests", dependencies: ["RepriseCore"]),
        .testTarget(name: "RepriseMCPTests", dependencies: ["RepriseMCPKit"]),
        .testTarget(name: "RepriseAppTests", dependencies: ["Reprise"])
    ],
    swiftLanguageModes: [.v5]
)
