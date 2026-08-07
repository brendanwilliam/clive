// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPhoneTerminal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "IPhoneTerminalCore", targets: ["IPhoneTerminalCore"]),
        .executable(name: "iphone-terminald", targets: ["IPhoneTerminalDaemon"]),
    ],
    targets: [
        .target(name: "IPhoneTerminalCore"),
        .executableTarget(name: "IPhoneTerminalDaemon", dependencies: ["IPhoneTerminalCore"]),
        .testTarget(name: "IPhoneTerminalCoreTests", dependencies: ["IPhoneTerminalCore"]),
    ]
)
