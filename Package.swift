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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.17.1")
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
        .target(
            name: "SMCtlDaemonCore",
            dependencies: [
                "SMCCore",
                "PolicyEngine",
                "SMCtlProtocol",
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "smctld",
            dependencies: [
                "SMCtlDaemonCore",
                "SMCtlProtocol"
            ]
        ),
        .executableTarget(
            name: "smctl",
            dependencies: [
                "SMCCore",
                "SMCtlProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SMCCoreTests",
            dependencies: ["SMCCore"]
        ),
        .testTarget(
            name: "PolicyEngineTests",
            dependencies: ["PolicyEngine"]
        ),
        .testTarget(
            name: "SMCtlProtocolTests",
            dependencies: ["SMCtlProtocol"]
        ),
        .testTarget(
            name: "SMCtlDaemonCoreTests",
            dependencies: ["SMCtlDaemonCore"]
        ),
        .testTarget(
            name: "smctlTests",
            dependencies: ["smctl"]
        )
    ]
)
