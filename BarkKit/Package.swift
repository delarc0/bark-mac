// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BarkKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BarkCore", targets: ["BarkCore"]),
        .library(name: "BarkEngine", targets: ["BarkEngine"]),
        .library(name: "BarkCapture", targets: ["BarkCapture"]),
        .library(name: "BarkStore", targets: ["BarkStore"]),
        .library(name: "BarkHQ", targets: ["BarkHQ"]),
        .library(name: "BarkCalendar", targets: ["BarkCalendar"]),
    ],
    dependencies: [
        // Silero v6 VAD for BarkEngine's segmenter, the offline diarizer (only its Diarizer trait); Parakeet in fluid-eval.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.2", traits: ["Diarizer"]),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
    ],
    targets: [
        .target(name: "BarkCore"),
        .target(
            name: "BarkEngine",
            dependencies: [
                "BarkCore",
                "BarkStore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(name: "BarkCapture", dependencies: ["BarkCore"]),
        // SQLite and AVFoundation from the SDK only.
        .target(name: "BarkStore"),
        // Foundation and Security from the SDK only.
        .target(name: "BarkHQ", dependencies: ["BarkStore", "BarkCore"]),
        // Foundation, Security and CryptoKit from the SDK only.
        .target(name: "BarkCalendar", dependencies: ["BarkCore"]),
        .testTarget(name: "BarkCoreTests", dependencies: ["BarkCore"]),
        .testTarget(name: "BarkCaptureTests", dependencies: ["BarkCapture"]),
        .testTarget(name: "BarkStoreTests", dependencies: ["BarkStore"]),
        .testTarget(name: "BarkHQTests", dependencies: ["BarkHQ", "BarkStore", "BarkCore"], exclude: ["Fixtures"]),
        .testTarget(name: "BarkCalendarTests", dependencies: ["BarkCalendar", "BarkCore"], exclude: ["Fixtures"]),
        .testTarget(name: "BarkEngineTests", dependencies: ["BarkEngine", "BarkStore", .product(name: "MLX", package: "mlx-swift")]),
        .executableTarget(
            name: "mlx-eval",
            dependencies: ["BarkEngine", "BarkStore", .product(name: "MLX", package: "mlx-swift")]
        ),
        .executableTarget(
            name: "fluid-eval",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "capture-probe", dependencies: ["BarkCapture", "BarkCore"]),
    ]
)
