// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Translater",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Translater", targets: ["Translater"])
    ],
    targets: [
        .executableTarget(name: "Translater")
    ],
    swiftLanguageModes: [.v5]
)
