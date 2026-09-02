// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrivateRelationshipNotebook",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "RelationshipCore", targets: ["RelationshipCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/jedisct1/swift-sodium.git",
            exact: "0.11.0"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        )
    ],
    targets: [
        .target(
            name: "RelationshipCore",
            dependencies: [
                .product(name: "Clibsodium", package: "swift-sodium"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/RelationshipCore"
        ),
        // Historical native-model routing remains available only to package
        // regression tests. This target is intentionally not a library product
        // and is also excluded from the production Xcode application target.
        .target(
            name: "RelationshipLegacyIntelligence",
            dependencies: ["RelationshipCore"],
            path: "Sources/RelationshipLegacyIntelligence",
            swiftSettings: [
                .define("RELATIONSHIP_LEGACY_INTELLIGENCE")
            ]
        ),
        .testTarget(
            name: "RelationshipCoreTests",
            dependencies: ["RelationshipCore"],
            path: "Tests/RelationshipCoreTests"
        ),
        .testTarget(
            name: "RelationshipLegacyIntelligenceTests",
            dependencies: [
                "RelationshipCore",
                "RelationshipLegacyIntelligence"
            ],
            path: "Tests/RelationshipLegacyIntelligenceTests"
        )
    ]
)
