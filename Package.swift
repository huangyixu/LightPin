// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LightPin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightPin", targets: ["LightPin"])],
    targets: [
        .executableTarget(name: "LightPin", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LightPinTests", dependencies: ["LightPin"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
