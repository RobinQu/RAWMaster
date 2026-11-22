// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let runtimeLibrary = "\(packageRoot)/Vendor/ONNXRuntime/lib"
let runtimeLinkSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(runtimeLibrary)"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", runtimeLibrary]),
]

let package = Package(
    name: "MaskAI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MaskAI", targets: ["MaskAI"]),
        .executable(name: "mask-ai-probe", targets: ["mask-ai-probe"]),
    ],
    targets: [
        .systemLibrary(name: "CONNXRuntime", path: "Sources/CONNXRuntime"),
        .target(name: "MaskAI", dependencies: ["CONNXRuntime"], linkerSettings: runtimeLinkSettings),
        .executableTarget(name: "mask-ai-probe", dependencies: ["MaskAI"]),
        .testTarget(name: "MaskAITests", dependencies: ["MaskAI"]),
    ],
    swiftLanguageModes: [.v5]
)
