// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NorIMAPKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "NorIMAPKit",
            targets: ["NorIMAPKit"]
        ),
        .library(
            name: "NorIMAPKitSMTP",
            targets: ["NorIMAPKitSMTP"]
        ),
    ],
    targets: [
        .target(
            name: "NorIMAPKit",
            path: "Sources/NorIMAPKit"
        ),
        .target(
            name: "NorIMAPKitSMTP",
            dependencies: ["NorIMAPKit"],
            path: "Sources/NorIMAPKitSMTP"
        ),
        .testTarget(
            name: "NorIMAPKitTests",
            dependencies: ["NorIMAPKit", "NorIMAPKitSMTP"],
            path: "Tests/NorIMAPKitTests"
        ),
    ]
)
