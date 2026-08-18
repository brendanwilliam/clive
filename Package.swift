// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPhoneTerminal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "IPhoneTerminalCore", targets: ["IPhoneTerminalCore"]),
        .library(name: "IPhoneTerminalSecurity", targets: ["IPhoneTerminalSecurity"]),
        .library(name: "IPhoneTerminalCloud", targets: ["IPhoneTerminalCloud"]),
        .executable(name: "iphone-terminald", targets: ["IPhoneTerminalDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
    ],
    targets: [
        .target(name: "IPhoneTerminalCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "IPhoneTerminalSecurity", dependencies: [
            "IPhoneTerminalCore",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "IPhoneTerminalCloud", dependencies: ["IPhoneTerminalCore"]),
        .executableTarget(name: "IPhoneTerminalDaemon", dependencies: ["IPhoneTerminalCore", "IPhoneTerminalSecurity", "IPhoneTerminalCloud"]),
        .testTarget(name: "IPhoneTerminalCoreTests", dependencies: ["IPhoneTerminalCore", "IPhoneTerminalSecurity"]),
    ]
)
