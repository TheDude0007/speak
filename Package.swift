// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Speak",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Speak", targets: ["Speak"]),
    ],
    targets: [
        // Pure logic: text cleanup + hotkey state machine. No AppKit, fully unit-tested.
        .target(name: "SpeakCore", path: "Sources/SpeakCore"),
        .executableTarget(
            name: "Speak",
            dependencies: ["SpeakCore"],
            path: "Sources/Speak",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SpeakCoreTests", dependencies: ["SpeakCore"], path: "Tests/SpeakCoreTests"),
    ]
)
