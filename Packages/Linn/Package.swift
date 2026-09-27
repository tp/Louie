// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Linn",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "LinnNowPlaying", targets: ["LinnNowPlaying"]),
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Linn",
            targets: ["Linn"]
        ),
    ],
    dependencies: [
        .package(path: "../LinnCiGateway"),
    ],
    targets: [
        .target(
            name: "LinnNowPlaying",
            dependencies: ["Linn", .product(name: "LinnCiGateway", package: "LinnCiGateway")]
        ),
        .testTarget(
            name: "LinnNowPlayingTests",
            dependencies: ["LinnNowPlaying", .product(name: "LinnCiGateway", package: "LinnCiGateway")]
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Linn",
            dependencies: [
                .product(name: "LinnCiGateway", package: "LinnCiGateway"),
            ]
        ),
        .testTarget(
            name: "LinnTests",
            dependencies: [
                "Linn",
                .product(name: "LinnCiGateway", package: "LinnCiGateway"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
