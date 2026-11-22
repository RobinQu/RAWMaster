// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoExport",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RAWMasterPhotoExport", targets: ["RAWMasterPhotoExport"])],
    targets: [
        .target(name: "RAWMasterPhotoExport", path: "Swift", plugins: ["BuildPhotoExport"]),
        .plugin(name: "BuildPhotoExport", capability: .buildTool(), path: "BuildPlugin")
    ],
    swiftLanguageModes: [.v5]
)
