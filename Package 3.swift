// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "HermesMobile",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "HermesMobile",
            targets: ["HermesMobile"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.4"),
        .package(url: "https://github.com/pointfreeco/swift-parsing.git", from: "0.6.0")
    ],
    targets: [
        .target(
            name: "HermesCoreWebSocket",
            path: "Sources/HermesCoreWebSocket"
        ),
        .target(
            name: "GeneratedModels",
            path: "Sources/Generated"
        ),
        .target(
            name: "Gateway",
            path: "Sources/Gateway"
        ),
        .target(
            name: "GatewayClient",
            path: "Sources/GatewayClient"
        ),
        .target(
            name: "HermesMobile",
            path: "Sources",
            exclude: [
                "HermesCoreWebSocket",
                "Generated",
                "Gateway",
                "GatewayClient"
            ],
            dependencies: [
                .target(name: "HermesCoreWebSocket"),
                .target(name: "GeneratedModels"),
                .target(name: "Gateway"),
                .target(name: "GatewayClient")
            ]
        ),
        .testTarget(
            name: "HermesMobileTests",
            dependencies: ["HermesMobile", "GeneratedModels"],
            path: "Tests"
        )
    ]
)
