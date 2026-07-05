// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "TokenPace",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "TokenPace", targets: ["TokenPace"]),
        .library(name: "TokenPaceKit", targets: ["TokenPaceKit"]),
    ],
    targets: [
        .executableTarget(
            name: "TokenPace",
            dependencies: ["TokenPaceKit"]
        ),
        .target(
            name: "TokenPaceKit"
        ),
        .testTarget(
            name: "TokenPaceKitTests",
            dependencies: ["TokenPaceKit"]
        ),
    ]
)
