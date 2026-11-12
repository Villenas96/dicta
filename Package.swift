// swift-tools-version:6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Dicta",
    platforms: [.macOS("26.0")],
    targets: [
        // Lógica pura (sin AppKit): atajo, aprendizaje, continuidad, prompts. Testeable.
        .target(name: "DictaCore", path: "Sources/DictaCore", swiftSettings: swift5),
        // App de barra de menús.
        .executableTarget(
            name: "Dicta",
            dependencies: ["DictaCore"],
            path: "Sources/Dicta",
            swiftSettings: swift5
        ),
        .testTarget(
            name: "DictaCoreTests",
            dependencies: ["DictaCore"],
            path: "Tests/DictaCoreTests",
            swiftSettings: swift5
        ),
    ]
)
