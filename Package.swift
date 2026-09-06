// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crisp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DisplayCore", targets: ["DisplayCore"]),
        .executable(name: "displayctl", targets: ["displayctl"]),
        .executable(name: "Crisp", targets: ["Crisp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(name: "DisplayCore"),
        .executableTarget(name: "displayctl", dependencies: ["DisplayCore"]),
        .executableTarget(name: "Crisp", dependencies: ["DisplayCore"]),
        .testTarget(
            name: "DisplayCoreTests",
            dependencies: [
                "DisplayCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "CrispTests",
            dependencies: [
                "Crisp",
                "DisplayCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "displayctlTests",
            dependencies: [
                "displayctl",
                "DisplayCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
