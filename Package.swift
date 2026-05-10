// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Nugumi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Nugumi", targets: ["Nugumi"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "Nugumi",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "NugumiTests",
            dependencies: ["Nugumi"]
        )
    ],
    swiftLanguageModes: [.v5]
)
