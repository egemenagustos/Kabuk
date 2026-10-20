// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kabuk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kabuk", targets: ["Kabuk"]),
        .executable(name: "kabuk-hook", targets: ["kabuk-hook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "KabukCore"),
        .executableTarget(
            name: "Kabuk",
            dependencies: ["KabukCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(name: "kabuk-hook", dependencies: ["KabukCore"]),
        .testTarget(name: "KabukCoreTests", dependencies: ["KabukCore"]),
    ]
)
