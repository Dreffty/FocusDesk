// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "FocusDesk", platforms: [.macOS(.v14)], products: [
    .executable(name: "FocusDesk", targets: ["FocusDesk"])
], targets: [
    .target(name: "FocusCore"),
    .executableTarget(name: "FocusDesk", dependencies: ["FocusCore"]),
    .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"])
])
