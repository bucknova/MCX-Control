// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MCXControl",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "MCXCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MCXControl", dependencies: ["MCXCore"]),
        .executableTarget(name: "MCXCoreCheck", dependencies: ["MCXCore"]),
    ]
)
