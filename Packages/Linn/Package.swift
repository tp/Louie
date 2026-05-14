// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Linn",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
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
