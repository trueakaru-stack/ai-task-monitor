// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AITaskMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AITaskMonitor", targets: ["AITaskMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "AITaskMonitor",
            path: "Sources/AITaskMonitor"
        ),
        .testTarget(
            name: "AITaskMonitorTests",
            dependencies: ["AITaskMonitor"],
            path: "Tests/AITaskMonitorTests"
        )
    ]
)
