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
    ],
    dependencies: [
        // Spike tools only (bark-eval, stream-eval): the WhisperKit/CoreML engine Bark2 replaces.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        // Silero v6 VAD for BarkEngine's segmenter; Parakeet in fluid-eval.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
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
        .target(name: "BarkHQ", dependencies: ["BarkStore"]),
        .testTarget(name: "BarkCoreTests", dependencies: ["BarkCore"]),
        .testTarget(name: "BarkCaptureTests", dependencies: ["BarkCapture"]),
        .testTarget(name: "BarkStoreTests", dependencies: ["BarkStore"]),
        .testTarget(name: "BarkHQTests", dependencies: ["BarkHQ", "BarkStore"], exclude: ["Fixtures"]),
        .testTarget(name: "BarkEngineTests", dependencies: ["BarkEngine", "BarkStore", .product(name: "MLX", package: "mlx-swift")]),
        .executableTarget(
            name: "mlx-eval",
            dependencies: ["BarkEngine", "BarkStore", .product(name: "MLX", package: "mlx-swift")]
        ),
        .executableTarget(
            name: "bark-eval",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        .executableTarget(
            name: "stream-eval",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "fluid-eval",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "capture-probe", dependencies: ["BarkCapture", "BarkCore"]),
    ]
)
