// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LectureKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LectureKit", targets: ["LectureKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "LectureKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(name: "LectureKitTests", dependencies: ["LectureKit"]),
    ]
)
