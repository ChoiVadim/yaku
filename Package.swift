// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Yaku",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Yaku", targets: ["Yaku"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "Yaku",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
