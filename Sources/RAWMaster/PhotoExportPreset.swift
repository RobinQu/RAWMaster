import Foundation
import RAWMasterCore
import RAWMasterImaging
import RAWMasterPhotoExport

/// Local selection, version IDs and the destination never enter this portable file.
struct PhotoExportPreset {
    var name: String
    var configuration: PhotoBatchExportConfiguration
    var namingTemplate: String
    var sizeChoice: Int
    var customLongEdge: Int
    var mode = "render"
    var copyMode = "files"
    var originalFormats = ExportFormats.allOriginals
    var collision = "rename"

    private static let kind = "rawmaster.export-preset"
    private static let formatIDs: [String: PhotoRenderFormat] = ["jpeg": .jpeg8, "tiff": .tiff16, "png": .png16]
    private static let originalIDs: [String: ExportFormats] = ["all": .allOriginals, "both": .both, "raw": .rawOnly, "jpeg": .jpegOnly]

    private static func invalid(_ message: String) -> LibraryError { .invalid(message) }

    private func portableLook() throws -> [String: Any] {
        let appearance = configuration.layout.resolvedAppearance
        let encoded = try JSONEncoder().encode(appearance)
        guard var look = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw Self.invalid("无法编码版式。") }
        if appearance.logo == nil { look["logo"] = NSNull() }
        return look
    }

    func fileData() throws -> Data {
        try configuration.validate()
        guard let format = Self.formatIDs.first(where: { $0.value == configuration.format })?.key,
              let originals = Self.originalIDs.first(where: { $0.value == originalFormats })?.key else { throw Self.invalid("未知文件类型。") }
        let settings: [String: Any] = ["mode": mode, "copyMode": copyMode, "originalFormat": originals,
            "format": format, "size": sizeChoice == -1 ? "custom" : String(sizeChoice), "edge": String(customLongEdge),
            "quality": String(Int((configuration.jpegQuality*100).rounded())), "color": "srgb", "template": namingTemplate,
            "collision": collision, "metadata": configuration.metadataPolicy.rawValue, "gps": configuration.includeGPS, "layout": try portableLook()]
        let root: [String: Any] = ["kind": Self.kind, "schemaVersion": 2, "name": name, "settings": settings]
        return try PhotoExportKernel.normalizePreset(JSONSerialization.data(withJSONObject: root))
    }

    static func read(_ data: Data) throws -> Self {
        let canonical = try PhotoExportKernel.normalizePreset(data)
        guard let root = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              let name = root["name"] as? String, let settings = root["settings"] as? [String: Any],
              let mode = settings["mode"] as? String, let copy = settings["copyMode"] as? String,
              let originals = originalIDs[settings["originalFormat"] as? String ?? ""],
              let format = formatIDs[settings["format"] as? String ?? ""], let identifier = settings["size"] as? String,
              let size = identifier == "custom" ? -1 : Int(identifier),
              let edge = Int(settings["edge"] as? String ?? ""), let quality = Int(settings["quality"] as? String ?? ""),
              let naming = settings["template"] as? String, let collision = settings["collision"] as? String,
              let policy = PhotoExportMetadataPolicy(rawValue: settings["metadata"] as? String ?? ""),
              let gps = settings["gps"] as? Bool, let look = settings["layout"] as? [String: Any] else {
            throw invalid("无法读取导出预设中的设置。")
        }
        let appearance = try JSONDecoder().decode(PhotoExportAppearance.self, from: JSONSerialization.data(withJSONObject: look))
        let layout = PhotoExportLayout(style: appearance.builtin, signature: appearance.signature, inkHex: appearance.ink,
                                       opacity: Double(appearance.opacity) / 100, appearance: appearance)
        let config = PhotoBatchExportConfiguration(format: format, maximumLongEdge: size == 0 ? nil : (size == -1 ? edge : size),
            jpegQuality: Double(quality) / 100, layout: layout, metadataPolicy: policy, includeGPS: gps)
        return Self(name: name, configuration: config, namingTemplate: naming, sizeChoice: size, customLongEdge: edge,
                    mode: mode, copyMode: copy, originalFormats: originals, collision: collision)
    }
}
