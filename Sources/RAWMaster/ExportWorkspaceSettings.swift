import Foundation
import RAWMasterCore
import RAWMasterImaging

struct ExportWorkspaceSettings: Equatable {
    var configuration = PhotoBatchExportConfiguration(format: .jpeg8, maximumLongEdge: 2048, jpegQuality: 0.9, metadataPolicy: .rights)
    var sizeChoice = 2048
    var customLongEdge = 3000
    var namingTemplate = "{name}-{index}"
    var mode = "render"
    var copyMode = "files"
    var originalFormats = ExportFormats.allOriginals
    var collision = "rename"

    init() {}

    init(preset: PhotoExportPreset) {
        configuration = preset.configuration
        sizeChoice = preset.sizeChoice
        customLongEdge = preset.customLongEdge
        namingTemplate = preset.namingTemplate
        mode = preset.mode
        copyMode = preset.copyMode
        originalFormats = preset.originalFormats
        collision = preset.collision
    }

    var resolvedConfiguration: PhotoBatchExportConfiguration {
        var result = configuration
        result.maximumLongEdge = sizeChoice == 0 ? nil : (sizeChoice == -1 ? customLongEdge : sizeChoice)
        return result
    }

    func portable(named name: String) -> PhotoExportPreset {
        PhotoExportPreset(name: name, configuration: resolvedConfiguration, namingTemplate: namingTemplate,
                          sizeChoice: sizeChoice, customLongEdge: customLongEdge, mode: mode,
                          copyMode: copyMode, originalFormats: originalFormats, collision: collision)
    }
}

struct ExportWorkspacePresetChoice: Identifiable {
    let id: String
    let name: String
    let settings: ExportWorkspaceSettings
    var importedName: String?

    static let builtins: [Self] = {
        var full = ExportWorkspaceSettings()
        full.sizeChoice = 0
        full.configuration.jpegQuality = 0.95
        var master = full
        master.configuration.format = .tiff16
        var portfolio = ExportWorkspaceSettings()
        portfolio.configuration.jpegQuality = 0.95
        portfolio.configuration.layout = PhotoExportLayout(style: .paper)
        var social = ExportWorkspaceSettings()
        social.sizeChoice = 1350
        social.configuration.layout = PhotoExportLayout(style: .mist)
        var originals = ExportWorkspaceSettings()
        originals.mode = "original"
        return [
            Self(id: "web", name: "网络分享", settings: .init()),
            Self(id: "full", name: "全尺寸 JPEG", settings: full),
            Self(id: "master", name: "精修 TIFF", settings: master),
            Self(id: "portfolio", name: "相纸作品集", settings: portfolio),
            Self(id: "social", name: "社交竖幅", settings: social),
            Self(id: "originals", name: "原件交付", settings: originals)
        ]
    }()
}

struct StoredWorkspaceExportPreset: Codable, Identifiable {
    var id = UUID()
    let data: Data
    var importedName: String?

    func choice() throws -> ExportWorkspacePresetChoice {
        let preset = try PhotoExportPreset.read(data)
        return .init(id: id.uuidString, name: preset.name, settings: ExportWorkspaceSettings(preset: preset), importedName: importedName)
    }
}

enum ExportWorkspacePresetLibrary {
    private static let key = "rawmaster.export.workspace.personal-presets.v1"
    private static let lastKey = "rawmaster.export.workspace.last-submission.v1"

    static func last(in defaults: UserDefaults = .standard) throws -> ExportWorkspacePresetChoice? {
        guard let data = defaults.data(forKey: lastKey) else { return nil }
        let preset = try PhotoExportPreset.read(data)
        return .init(id: "last", name: "上次设置", settings: .init(preset: preset))
    }

    static func remember(_ settings: ExportWorkspaceSettings, in defaults: UserDefaults = .standard) throws {
        defaults.set(try settings.portable(named: "上次设置").fileData(), forKey: lastKey)
    }

    static func records(in defaults: UserDefaults = .standard) throws -> [StoredWorkspaceExportPreset] {
        guard let stored = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([StoredWorkspaceExportPreset].self, from: stored)
    }

    static func matching(_ preset: PhotoExportPreset, among choices: [ExportWorkspacePresetChoice]) throws -> ExportWorkspacePresetChoice? {
        let data = try preset.fileData()
        return choices.first { choice in
            let names = [choice.name, choice.importedName].compactMap { $0 }
            return names.contains { $0.localizedCaseInsensitiveCompare(preset.name) == .orderedSame } &&
                (try? choice.settings.portable(named: preset.name).fileData()) == data
        }
    }

    static func availableName(_ suggested: String, among choices: [ExportWorkspacePresetChoice]) -> String {
        let names = Set(choices.map { $0.name.lowercased() })
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " \(number)"
            var head = suggested
            while head.utf16.count + suffix.utf16.count > 70 { head.removeLast() }
            let candidate = head + suffix
            if !names.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    static func append(_ preset: PhotoExportPreset, importedName: String? = nil,
                       to defaults: UserDefaults = .standard) throws -> ExportWorkspacePresetChoice {
        var records = try records(in: defaults)
        let record = try StoredWorkspaceExportPreset(data: preset.fileData(), importedName: importedName)
        let choice = try record.choice()
        records.append(record)
        defaults.set(try JSONEncoder().encode(records), forKey: key)
        return choice
    }
}
