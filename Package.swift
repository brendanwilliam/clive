// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CliveCore", targets: ["CliveCore"]),
        .library(name: "CliveSecurity", targets: ["CliveSecurity"]),
        .library(name: "CliveCloud", targets: ["CliveCloud"]),
        .executable(name: "clive", targets: ["CliveDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.20.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
    ],
    targets: [
        .target(name: "CliveCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "CliveSecurity", dependencies: [
            "CliveCore",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "CliveCloud", dependencies: ["CliveCore"]),
        .executableTarget(name: "CliveDaemon", dependencies: ["CliveCore", "CliveSecurity", "CliveCloud"]),
        .testTarget(name: "CliveCoreTests", dependencies: ["CliveCore", "CliveSecurity"]),
        .testTarget(name: "CliveDaemonTests", dependencies: ["CliveDaemon", "CliveCore"]),
    ]
)
