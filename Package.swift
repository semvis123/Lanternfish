// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lanternfish",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "LanternfishKit", targets: ["LanternfishKit"]),
        .executable(name: "Lanternfish", targets: ["Lanternfish"]),
    ],
    targets: [
        .target(
            name: "LanternfishKit",
            resources: [.copy("Resources/oui.tsv")]
        ),
        .executableTarget(
            name: "Lanternfish",
            dependencies: ["LanternfishKit"]
        ),
        .testTarget(
            name: "LanternfishKitTests",
            dependencies: ["LanternfishKit"]
        ),
    ]
)
