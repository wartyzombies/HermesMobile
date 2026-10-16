// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HermesMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // App / client library consumed by the iOS app target.
        .library(name: "HermesMobile", targets: ["HermesMobile"]),
        // Standalone low-level WebSocket transport (no app deps).
        .library(name: "HermesCoreWebSocket", targets: ["HermesCoreWebSocket"]),
        // Machine-generated wire models (from gateway-contract.openrpc.json).
        .library(name: "GeneratedModels", targets: ["GeneratedModels"]),
    ],
    dependencies: [
        // No external runtime deps in core; the app target brings SwiftUI.
        // Future: swift-crypto if PKCE needs a hardened implementation.
    ],
    targets: [
        // App / client library.
        //
        // `exclude` keeps SwiftPM from recursively claiming the subdirectories
        // that belong to the sibling target below. Without it SwiftPM reports
        // "target 'HermesCoreWebSocket' has overlapping sources" and refuses
        // to build a single file (fixes.md R1).
        .target(
            name: "HermesMobile",
            dependencies: ["GeneratedModels", "HermesLogger"],
            path: "Sources",
            exclude: ["HermesCoreWebSocket", "Generated", "HermesLogger"]
        ),
        // Low-level URLSessionWebSocketTask transport.
        .target(name: "HermesCoreWebSocket", dependencies: ["HermesLogger"], path: "Sources/HermesCoreWebSocket"),
        // Cross-platform logging shim (OSLog on Apple, print on Linux).
        .target(name: "HermesLogger", path: "Sources/HermesLogger"),
        // Machine-generated wire models. No bundled resources: the generators
        // read openrpc.json from the repo root and emit only .swift files (Y6).
        .target(name: "GeneratedModels", path: "Sources/Generated"),
        // Unit tests.
        .testTarget(
            name: "HermesMobileTests",
            dependencies: ["HermesMobile"],
            path: "Tests"
        ),
        // NOTE (Y5): `Scripts/` holds the Python code generators and is NOT a
        // SwiftPM target — it contains no Swift. Run them directly:
        //   python3 Scripts/gen_models.py
        //   python3 Scripts/gen_client.py
    ]
)

