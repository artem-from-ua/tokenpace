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
        // No `resources:`. The bar-style preview thumbnails used to live here as PNGs; they are drawn
        // at runtime now (`BarStylePreviewRenderer`), so the target ships no resource bundle at all.
        // Adding one back means re-reading the resource rules in `docs/reference/conventions.md` —
        // `Bundle.module` does not work inside a real `.app` (ADR-0095).
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
