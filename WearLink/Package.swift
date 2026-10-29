// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WearLink",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WearLink", targets: ["WearLink"]),
    ],
    targets: [
        .target(name: "WearLink"),
        .testTarget(name: "WearLinkTests", dependencies: ["WearLink"]),
    ]
)
