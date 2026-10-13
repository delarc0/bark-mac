// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BarkKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BarkCore", targets: ["BarkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        // Eval-only for now (Parakeet, Silero); P1 brings it into the app for the Silero gate.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
        // Spike S8: the MLX Whisper engine (eval/mlx.sh).
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .target(name: "BarkCore"),
        .testTarget(name: "BarkCoreTests", dependencies: ["BarkCore"]),
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
        .executableTarget(
            name: "mlx-eval",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                // The vendored swift-transformers tokenizer (AutoTokenizerWrapper) and the WAV loader.
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ]
)
