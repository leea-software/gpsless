// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GPSLessCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GPSLessCore", targets: ["GPSLessCore"])],
    targets: [
        .target(name: "GPSLessCore", path: "Core"),
        .testTarget(name: "GPSLessCoreTests", dependencies: ["GPSLessCore"], path: "Tests")
    ]
)
