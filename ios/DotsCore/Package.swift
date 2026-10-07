// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DotsCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DotsCore", targets: ["DotsCore"]),
        .executable(name: "DotsProbe", targets: ["DotsProbe"])
    ],
    targets: [
        .target(name: "DotsCore"),
        .executableTarget(name: "DotsProbe", dependencies: ["DotsCore"]),
        .testTarget(name: "DotsCoreTests", dependencies: ["DotsCore"])
    ]
)
