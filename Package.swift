// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPhoneTerminal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "IPhoneTerminalCore", targets: ["IPhoneTerminalCore"]),
        .library(name: "IPhoneTerminalSecurity", targets: ["IPhoneTerminalSecurity"]),
        .executable(name: "iphone-terminald", targets: ["IPhoneTerminalDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
    ],
    targets: [
        .target(name: "IPhoneTerminalCore"),
        .target(name: "IPhoneTerminalSecurity", dependencies: [
            "IPhoneTerminalCore",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .executableTarget(name: "IPhoneTerminalDaemon", dependencies: ["IPhoneTerminalCore", "IPhoneTerminalSecurity"]),
        .testTarget(name: "IPhoneTerminalCoreTests", dependencies: ["IPhoneTerminalCore", "IPhoneTerminalSecurity"]),
    ]
)
