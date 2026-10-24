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
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "RAWMasterCore", dependencies: ["CSQLite"]),
        .target(name: "RAWMasterImaging", dependencies: ["RAWMasterCore"]),
        .executableTarget(name: "RAWMaster", dependencies: ["RAWMasterCore", "RAWMasterImaging"]),
        .executableTarget(name: "RAWMasterDiagnostics", dependencies: ["RAWMasterCore", "RAWMasterImaging"]),
        .executableTarget(name: "RAWMasterSequenceProbe", dependencies: ["RAWMasterCore", "RAWMasterImaging"]),
        .testTarget(name: "RAWMasterCoreTests", dependencies: ["RAWMasterCore"]),
        .testTarget(name: "RAWMasterImagingTests", dependencies: ["RAWMasterImaging", "RAWMasterCore", "RAWMasterSequenceProbe"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RAWMasterUITests", dependencies: ["RAWMaster", "RAWMasterCore"]),
        .testTarget(name: "RAWMasterDiagnosticsTests", dependencies: ["RAWMasterDiagnostics"]),
        .testTarget(name: "RAWMasterSequenceProbeTests", dependencies: ["RAWMasterSequenceProbe"])
    ],
    swiftLanguageModes: [.v5]
)
