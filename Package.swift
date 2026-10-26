// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContractGateway",
    // Only platforms the CI workflow builds: iOS (Simulator, via xcodebuild) and macOS.
    // Linux is built and tested too (core module only); it needs no declaration.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ContractGateway", targets: ["ContractGateway"]),
        .library(name: "ContractGatewayUI", targets: ["ContractGatewayUI"]),
    ],
    targets: [
        .target(name: "ContractGateway"),
        .target(name: "ContractGatewayUI", dependencies: ["ContractGateway"]),
        .testTarget(name: "ContractGatewayTests", dependencies: ["ContractGateway"]),
    ]
)
