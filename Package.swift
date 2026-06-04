// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "smctl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SMCCore", targets: ["SMCCore"]),
        .library(name: "PolicyEngine", targets: ["PolicyEngine"]),
        .library(name: "SMCtlProtocol", targets: ["SMCtlProtocol"]),
        .executable(name: "smctld", targets: ["smctld"]),
        .executable(name: "smctl", targets: ["smctl"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SMCCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(name: "PolicyEngine"),
        .target(name: "SMCtlProtocol"),
        .executableTarget(name: "smctld"),
        .executableTarget(
            name: "smctl",
            dependencies: [
                "SMCCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SMCCoreTests",
            dependencies: ["SMCCore"]
        )
    ]
)
