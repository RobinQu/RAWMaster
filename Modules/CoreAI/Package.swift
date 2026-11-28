// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreAI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RAWMasterCoreAI", targets: ["RAWMasterCoreAI"])],
    targets: [
        .target(name: "CCoreAI", path: "Bridge", publicHeadersPath: "include"),
        .target(name: "RAWMasterCoreAI", dependencies: ["CCoreAI"], path: "Swift", plugins: ["BuildCoreAI"]),
        .plugin(name: "BuildCoreAI", capability: .buildTool(), path: "BuildPlugin")
    ]
)
