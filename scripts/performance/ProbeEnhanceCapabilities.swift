// swift scripts/performance/ProbeEnhanceCapabilities.swift /path/to/real.ARW
import CoreImage
import Foundation
import VideoToolbox

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Expected a real RAW file.\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let raw = CIRAWFilter(imageURL: url) else {
    FileHandle.standardError.write(Data("Core Image could not open the source.\n".utf8))
    exit(1)
}
var report: [String: Any] = [
    "nativeSize": [Int(raw.nativeSize.width), Int(raw.nativeSize.height)],
    "defaultVersion": raw.decoderVersion.rawValue,
    "supportedVersions": raw.supportedDecoderVersions.map(\.rawValue)
]
if #available(macOS 27, *), let neural = raw.supportedDecoderVersions.first(where: { ["9", "9.dng"].contains($0.rawValue) }) {
    raw.decoderVersion = neural
    report["neuralVersion"] = raw.decoderVersion.rawValue
    report["luminanceSupported"] = raw.isLuminanceNoiseReductionSupported
    report["chromaSupported"] = raw.isColorNoiseReductionSupported
    report["detailSupported"] = raw.isDetailSupported
}
if #available(macOS 26, *) {
    report["superResolutionSupported"] = VTSuperResolutionScalerConfiguration.isSupported
    report["superResolutionScaleFactors"] = VTSuperResolutionScalerConfiguration.supportedScaleFactors
    var configurations: [String: Bool] = [:]
    for (width, height) in [(512, 512), (1920, 1080), (Int(raw.nativeSize.width), Int(raw.nativeSize.height))] {
        for factor in [2, 4] {
            configurations["\(width)x\(height)@\(factor)"] = VTSuperResolutionScalerConfiguration(
                frameWidth: width, frameHeight: height, scaleFactor: factor, inputType: .image,
                usePrecomputedFlow: false, qualityPrioritization: .normal, revision: .revision1) != nil
        }
    }
    report["configurations"] = configurations
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
