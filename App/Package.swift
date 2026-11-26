// swift-tools-version: 6.2

import PackageDescription

// The Pulse menu bar app. A separate package so the app can target the current
// macOS (SwiftUI, Liquid Glass) while the core package keeps smctl's macOS 14
// floor. Open this file in Xcode to work on the UI with previews; build the
// distributable app with scripts/build-app.sh.
let package = Package(
    name: "PulseApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Pulse", targets: ["PulseApp"])
    ],
    dependencies: [
        // The repository root (package identity = folder name).
        .package(name: "pulse", path: "..")
    ],
    targets: [
        .target(
            name: "PulseUI",
            dependencies: [
                .product(name: "ProductIdentity", package: "pulse"),
                .product(name: "SMCCore", package: "pulse"),
                .product(name: "PolicyEngine", package: "pulse"),
                .product(name: "SMCtlProtocol", package: "pulse"),
                .product(name: "SMCtlClient", package: "pulse")
            ]
        ),
        .executableTarget(
            name: "PulseApp",
            dependencies: ["PulseUI"]
        ),
        // Renders the views with sample data to PNG files, to review the UI
        // without clicking through the menu bar: swift run PulseSnapshots <dir>
        .executableTarget(
            name: "PulseSnapshots",
            dependencies: ["PulseUI"]
        ),
        // Measures the app's CPU and memory with the real status item, popover
        // and settings window: swift run -c release PulseBench [seconds]
        .executableTarget(
            name: "PulseBench",
            dependencies: ["PulseUI"]
        ),
        .testTarget(
            name: "PulseUITests",
            dependencies: ["PulseUI"]
        )
    ]
)
