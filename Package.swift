// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingDebrief",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetingDebrief",
            path: "Sources/MeetingDebrief"
        )
    ]
)
