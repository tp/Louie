// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LinnCiGateway",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LinnCiGateway",
            targets: ["LinnCiGateway"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LinnCiGateway",
            exclude: ["openapi.original.yaml", "openapi.yaml"]
        ),
        .testTarget(
            name: "LinnCiGatewayTests",
            dependencies: ["LinnCiGateway"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
