// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SubspaceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SubspaceKit", targets: ["SubspaceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/ibireme/yyjson", .upToNextMinor(from: "0.13.0")),
    ],
    targets: [
        .target(
            name: "SubspaceKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "yyjson", package: "yyjson"),
            ],
            exclude: ["Resources/README.md"],
            resources: [.copy("Resources/Mappings")]
        ),
        .testTarget(
            name: "SubspaceKitTests",
            dependencies: ["SubspaceKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
