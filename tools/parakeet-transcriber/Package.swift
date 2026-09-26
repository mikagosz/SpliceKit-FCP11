// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "parakeet-transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        // mikagosz: przypięte — od 0.13.7 transcribe(_:source:) zamienia się
        // w transcribe(_:decoderState:language:) i main.swift się nie kompiluje.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.6"),
    ],
    targets: [
        .executableTarget(
            name: "parakeet-transcriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
    ]
)
