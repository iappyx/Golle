// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Golle",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Golle",
            path: "Sources/Golle",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
