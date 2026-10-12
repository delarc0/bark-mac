// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BarkKit",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        // Eval-only for now (Parakeet, Silero); P1 brings it into the app for the Silero gate.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
    ],
    targets: [
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
    ]
)
