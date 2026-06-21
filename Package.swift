// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "cc-timer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "cc-timer", targets: ["cc-timer"]),
        .library(name: "CCTimerKit", targets: ["CCTimerKit"]),
    ],
    targets: [
        .executableTarget(
            name: "cc-timer",
            dependencies: ["CCTimerKit"]
        ),
        .target(
            name: "CCTimerKit"
        ),
        .testTarget(
            name: "CCTimerKitTests",
            dependencies: ["CCTimerKit"]
        ),
    ]
)
