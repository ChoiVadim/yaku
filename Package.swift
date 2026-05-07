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
    targets: [
        .executableTarget(name: "Yaku")
    ],
    swiftLanguageModes: [.v5]
)
