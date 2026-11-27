// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RAWMaster",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RAWMasterCore", targets: ["RAWMasterCore"]),
        .executable(name: "RAWMaster", targets: ["RAWMaster"]),
        .executable(name: "RAWMasterDiagnostics", targets: ["RAWMasterDiagnostics"]),
        .executable(name: "RAWMasterSequenceProbe", targets: ["RAWMasterSequenceProbe"])
    ],
    dependencies: [.package(url: "https://github.com/sanzaru/SimpleToast.git", exact: "0.12.0"), .package(path: "experiments/MaskAI"), .package(path: "Modules/LibraryCatalog"), .package(path: "Modules/PhotoExport"), .package(path: "Modules/ImageEdit")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CFlashRaw"),
        .target(name: "RAWMasterCore", dependencies: ["CSQLite", .product(name: "RAWMasterLibrary", package: "LibraryCatalog"), .product(name: "RAWMasterPhotoExport", package: "PhotoExport")], resources: [.copy("Resources/AdobePresetMigration-v1.json")]),
        .target(name: "RAWMasterImaging", dependencies: ["RAWMasterCore", "CFlashRaw", .product(name: "MaskAI", package: "MaskAI"), .product(name: "RAWMasterPhotoExport", package: "PhotoExport"), .product(name: "RAWMasterImage", package: "ImageEdit"), .product(name: "RAWMasterLibrary", package: "LibraryCatalog")],
                resources: [.copy("Resources/PhotoFilters"), .copy("Resources/PhotoDenoise"), .copy("Resources/PhotoSuperResolution"), .copy("Resources/SceneColor")]),
        .target(name: "RAWMasterAI", dependencies: ["RAWMasterCore"], resources: [.copy("Resources")]),
        // VideoPlayer's SwiftUI overlay needs the Objective-C AVPlayerView superclass at runtime.
        // Importing AVKit alone can autolink only _AVKit_SwiftUI, causing an abort on first preview.
        .executableTarget(name: "RAWMaster", dependencies: ["RAWMasterCore", "RAWMasterImaging", "RAWMasterAI", .product(name: "SimpleToast", package: "SimpleToast"), .product(name: "RAWMasterLibrary", package: "LibraryCatalog"), .product(name: "RAWMasterPhotoExport", package: "PhotoExport")],
                          resources: [.copy("Resources/LibraryFolder.png")],
                          linkerSettings: [.linkedFramework("AVKit")]),
        .executableTarget(name: "RAWMasterDiagnostics", dependencies: ["RAWMasterCore", "RAWMasterImaging"]),
        .executableTarget(name: "RAWMasterSequenceProbe", dependencies: ["RAWMasterCore", "RAWMasterImaging"]),
        .testTarget(name: "RAWMasterCoreTests", dependencies: ["RAWMasterCore"]),
        .testTarget(name: "RAWMasterAITests", dependencies: ["RAWMasterAI", "RAWMasterCore"]),
        .testTarget(name: "RAWMasterImagingTests", dependencies: ["RAWMasterImaging", "RAWMasterCore", "RAWMasterSequenceProbe", .product(name: "RAWMasterImage", package: "ImageEdit")], resources: [.copy("Fixtures")]),
        .testTarget(name: "RAWMasterUITests", dependencies: ["RAWMaster", "RAWMasterCore", .product(name: "RAWMasterLibrary", package: "LibraryCatalog")]),
        .testTarget(name: "RAWMasterDiagnosticsTests", dependencies: ["RAWMasterDiagnostics"]),
        .testTarget(name: "RAWMasterSequenceProbeTests", dependencies: ["RAWMasterSequenceProbe"])
    ],
    swiftLanguageModes: [.v5]
)
