// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WearLink",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WearLink", targets: ["WearLink"]),
        .executable(name: "wearlink-pair", targets: ["wearlink-pair"]),
    ],
    targets: [
        .target(name: "WearLink"),
        // macOS pairing tester. The embedded Info.plist carries the Bluetooth usage string
        // macOS requires before a command-line tool may use CoreBluetooth.
        .executableTarget(
            name: "wearlink-pair",
            dependencies: ["WearLink"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Support/wearlink-pair-Info.plist",
            ])]
        ),
        .testTarget(name: "WearLinkTests", dependencies: ["WearLink"]),
    ]
)
