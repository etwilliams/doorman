// swift-tools-version:5.10
import PackageDescription

// DoormanCore holds everything that does not need AppKit (config, rules,
// browser discovery, favicon parsing) so it can be unit tested on its own.
// Doorman is the app itself. build.sh wraps the executable in Doorman.app;
// Doorman.xcodeproj builds the same app in Xcode.
let package = Package(
    name: "Doorman",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Doorman", targets: ["Doorman"]),
        // For Doorman.xcodeproj, whose app target builds the same sources as
        // the Doorman executable but links this from the package.
        .library(name: "DoormanCore", targets: ["DoormanCore"]),
    ],
    targets: [
        .target(name: "DoormanCore"),
        .executableTarget(name: "Doorman", dependencies: ["DoormanCore"]),
        .testTarget(name: "DoormanCoreTests", dependencies: ["DoormanCore"]),
    ]
)
