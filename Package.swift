// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "reclaim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReclaimCore", targets: ["ReclaimCore"]),
        .executable(name: "reclaim", targets: ["reclaim-cli"]),
        .executable(name: "ReclaimApp", targets: ["ReclaimApp"]),
    ],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "reclaim-cli", dependencies: ["ReclaimCore"]),
        .executableTarget(name: "ReclaimApp", dependencies: ["ReclaimCore"],
                          linkerSettings: [.linkedFramework("Photos"),
                                           .linkedFramework("Quartz")]),
        .testTarget(name: "ReclaimCoreTests", dependencies: ["ReclaimCore"]),
    ],
    swiftLanguageModes: [.v6]
)
