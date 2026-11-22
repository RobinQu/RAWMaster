// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibraryCatalog",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RAWMasterLibrary", targets: ["RAWMasterLibrary"])],
    targets: [
        .target(name: "CLibraryCatalogABI", path: "Bridge", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("dl", .when(platforms: [.linux]))]),
        .target(name: "RAWMasterLibrary", dependencies: ["CLibraryCatalogABI"], path: "Swift",
                resources: [.copy("Resources/catalog-format.json"), .copy("Resources/discovery")], plugins: ["BuildLibraryCatalog"]),
        .plugin(name: "BuildLibraryCatalog", capability: .buildTool(), path: "BuildPlugin")
    ]
)
