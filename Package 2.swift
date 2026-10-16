// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MyPackage",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "MyLibrary",
            targets: ["MyTarget"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "MyTarget",
            dependencies: [
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Sources/MyTarget"
        ),
        .testTarget(
            name: "MyTargetTests",
            dependencies: ["MyTarget"],
            path: "Tests/MyTargetTests"
        ),
    ]
)
