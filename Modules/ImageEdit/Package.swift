// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageEdit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RAWMasterImage", targets: ["RAWMasterImage"])],
    targets: [
        .target(name: "CImageEditABI", path: "Bridge", linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        .target(name: "RAWMasterImage", dependencies: ["CImageEditABI"], path: "Swift", plugins: ["BuildImageEdit"]),
        .plugin(name: "BuildImageEdit", capability: .buildTool(), path: "BuildPlugin")
    ]
)
