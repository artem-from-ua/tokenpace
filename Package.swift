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
            dependencies: ["TokenPaceKit"],
            // Bar-style preview thumbnails shown by the Settings picker. `.process` puts them in a
            // `TokenPace_TokenPace.bundle` reachable via `Bundle.module`; `scripts/build-app.sh`
            // copies that bundle into the `.app`, which it does not do for free.
            resources: [.process("Resources")]
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
