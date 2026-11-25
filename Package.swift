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
        .library(name: "SMCtlClient", targets: ["SMCtlClient"]),
        .executable(name: "pulsed", targets: ["smctld"]),
        .executable(name: "pulse", targets: ["smctl"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.17.1")
    ],
    targets: [
        .target(name: "ProductIdentity"),
        .target(
            name: "SMCCore",
            dependencies: ["ProductIdentity"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(name: "PolicyEngine"),
        .target(
            name: "SMCtlProtocol",
            dependencies: ["ProductIdentity", "PolicyEngine"]
        ),
        .target(
            name: "SMCtlClient",
            dependencies: ["ProductIdentity", "SMCtlProtocol", "PolicyEngine"]
        ),
        .target(
            name: "DisplayDDC",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreDisplay")
            ]
        ),
        .target(
            name: "SMCtlDaemonCore",
            dependencies: [
                "ProductIdentity",
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
                "ProductIdentity",
                "SMCCore",
                "PolicyEngine",
                "SMCtlProtocol",
                "SMCtlClient",
                "DisplayDDC",
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
            name: "SMCtlClientTests",
            dependencies: ["SMCtlClient", "SMCtlProtocol"]
        ),
        .testTarget(
            name: "SMCtlDaemonCoreTests",
            dependencies: ["ProductIdentity", "SMCtlDaemonCore"]
        ),
        .testTarget(
            name: "smctlTests",
            dependencies: ["ProductIdentity", "smctl", "DisplayDDC"]
        )
    ]
)
