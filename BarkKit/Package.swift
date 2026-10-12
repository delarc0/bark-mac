// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BarkKit",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        // Eval-only (Parakeet and Silero comparisons). No app-facing target may depend on it.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "bark-eval",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        .executableTarget(
            name: "fluid-eval",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
