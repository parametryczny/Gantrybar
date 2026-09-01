// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Gantry",
    platforms: [.macOS("13.0")],
    products: [
        .executable(name: "Gantry", targets: ["Gantry"])
    ],
    targets: [
        .systemLibrary(name: "CCommonCrypto", path: "Sources/CCommonCrypto"),
        .executableTarget(
            name: "Gantry",
            dependencies: ["CCommonCrypto"],
            path: "Sources/Gantry"
        ),
        .testTarget(
            name: "GantryTests",
            dependencies: ["Gantry"],
            path: "Tests/GantryTests"
        )
    ]
)
