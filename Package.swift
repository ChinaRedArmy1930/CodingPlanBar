// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodingPlanBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CodingPlanBar",
            path: "Sources/CodingPlanBar"
        )
    ]
)
