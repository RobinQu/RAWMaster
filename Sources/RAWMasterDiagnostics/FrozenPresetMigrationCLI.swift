import Foundation
import RAWMasterCore

enum FrozenPresetMigrationCLI {
    static let usage = "RAWMasterDiagnostics --migrate-frozen-presets <031-manifest.json> [--apply] [--catalog <directory>] [--system-root <directory>] [--user-root <directory>]"

    private struct Capability: Encodable {
        let sha256, capability, availableAction: String
        let visible: Bool
        let lookResolution: String?

        init(_ record: DevelopmentPresetRecord, stage: PresetExchangeStage) throws {
            sha256 = record.sourceSHA256 ?? ""
            capability = record.metadata["capability"] ?? "unknown"
            visible = record.isBrowsable
            lookResolution = record.metadata["lookResolution"]
            if !visible {
                availableAction = "hiddenDependency"
            } else if record.blockingReasons.isEmpty && !record.patch.isEmpty {
                availableAction = record.patch.resetLensBlur == true ? "lensBlurReset" : "strictParameterPatch"
            } else if capability == "lensBlur", case .approximate = try stage.lensBlurAssessment(for: record) {
                availableAction = "confirmedNativeDepthApproximation"
            } else if let variant = try? DevelopmentPresetExchange.semanticReconstruction(for: record),
                      let target = variant.patch.semanticMasks?.first?.target {
                availableAction = target == .subject ? "confirmedSubjectReconstruction" : "confirmedSkyReconstruction"
            } else if (try? DevelopmentPresetExchange.subset(for: record)) != nil {
                availableAction = "confirmedGlobalSubset"
            } else {
                availableAction = "inspectionOnly"
            }
        }
    }

    private struct Receipt: Encodable {
        let schemaVersion = 1
        let status, manifestSHA256, batchID, destination: String
        let recordsBefore, recordsAfter, favoritesBefore, favoritesAfter, batchesBefore, batchesAfter: Int
        let oldRecordsPreserved, favoritesPreserved, oldBatchIDsPreserved, frozenBatchPreviouslyRemoved: Bool
        let sourceCountByOrigin, inspectionCounts, capabilityCounts, availableActionCounts: [String: Int]
        let browsable, originalsVerifiedInCatalog, originalBytesVerifiedInCatalog: Int
        let addedIDs: [String]
        let files: [PresetInspectionItem]
        let capabilities: [Capability]
    }

    static func run(_ args: [String]) throws -> Int32 {
        guard let filename = args.first, !filename.hasPrefix("--") else { throw invalid(usage) }
        let manifest = URL(fileURLWithPath: filename)
        var paths = [String: URL]()
        var apply = false
        var index = 1
        while index < args.count {
            let option = args[index]
            if option == "--apply", !apply {
                apply = true
            } else if ["--catalog", "--system-root", "--user-root"].contains(option), paths[option] == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty {
                index += 1
                paths[option] = URL(fileURLWithPath: args[index], isDirectory: true)
            } else {
                throw invalid(usage)
            }
            index += 1
        }
        let system = paths["--system-root"] ?? DevelopmentPresetExchange.systemRoot
        let user = paths["--user-root"] ?? DevelopmentPresetExchange.userRoot
        let destination = paths["--catalog"] ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RAWMaster/Presets", isDirectory: true)
        guard !overlaps(destination, system), !overlaps(destination, user) else {
            throw invalid("预设库须与两个 Adobe 源目录分开")
        }
        let catalog = paths["--catalog"].map { DevelopmentPresetCatalog(root: $0) } ?? .shared
        let before = try catalog.snapshot()
        let priorBatchIDs = try catalog.importBatchIDs()
        let stage = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: manifest, system: system, user: user, catalog: catalog)
        let priorIDs = Set(before.records.map(\.id))
        var addedIDs = [String]()
        if apply && stage.frozenMigrationReady { addedIDs = try stage.commit(to: catalog) }

        let after = try catalog.snapshot()
        let batchIDs = try catalog.importBatchIDs()
        let afterRows = Dictionary(uniqueKeysWithValues: after.records.map { ($0.id, $0) })
        let oldRecordsPreserved = before.records.allSatisfy { old in
            guard var current = afterRows[old.id] else { return false }
            guard old != current else { return true }
            // The exchange may append source locations when identical bytes were already held independently.
            let oldLocations = locations(old.metadata["sourceLocationsV1"])
            let newLocations = locations(current.metadata["sourceLocationsV1"])
            current.metadata["sourceLocationsV1"] = old.metadata["sourceLocationsV1"]
            return current == old && oldLocations.isSubset(of: newLocations)
        }
        let oldBatchIDsPreserved = Set(priorBatchIDs).isSubset(of: Set(batchIDs))
        let favoritesPreserved = before.favorites == after.favorites
        var verified = 0
        var catalogBytes = 0
        for record in stage.records where apply && stage.frozenMigrationReady || priorIDs.contains(record.id) {
            guard let hash = record.sourceSHA256, afterRows[record.id]?.sourceSHA256 == hash else {
                throw invalid("目录中的内容标识与冻结清单不符")
            }
            // originalData verifies the bytes against the address. The same SHA and byte count were checked at the source.
            catalogBytes += try catalog.originalData(sha256: hash).count
            verified += 1
        }
        let capabilities = try stage.records.map { try Capability($0, stage: stage) }
        let status = stage.frozenMigrationReady ? (apply ? "applied" : "ready") : "blocked"
        let report = Receipt(status: status, manifestSHA256: DevelopmentPresetExchange.frozenMigrationV1SHA256,
            batchID: stage.batchID, destination: destination.path, recordsBefore: before.records.count, recordsAfter: after.records.count,
            favoritesBefore: before.favorites.count, favoritesAfter: after.favorites.count,
            batchesBefore: priorBatchIDs.count, batchesAfter: batchIDs.count, oldRecordsPreserved: oldRecordsPreserved,
            favoritesPreserved: favoritesPreserved, oldBatchIDsPreserved: oldBatchIDsPreserved,
            frozenBatchPreviouslyRemoved: stage.frozenBatchPreviouslyRemoved,
            sourceCountByOrigin: counts(stage.items.map(\.origin)), inspectionCounts: counts(stage.items.map { $0.status.rawValue }),
            capabilityCounts: counts(capabilities.map(\.capability)), availableActionCounts: counts(capabilities.map(\.availableAction)),
            browsable: stage.visibleCount, originalsVerifiedInCatalog: verified, originalBytesVerifiedInCatalog: catalogBytes,
            addedIDs: addedIDs.sorted(), files: stage.items, capabilities: capabilities)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([10]))
        return stage.frozenMigrationReady && oldRecordsPreserved && favoritesPreserved && oldBatchIDsPreserved ? 0 : 1
    }

    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let left = a.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let right = b.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return left.starts(with: right) || right.starts(with: left)
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
    }

    private static func locations(_ text: String?) -> Set<String> {
        guard let text, let array = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else { return [] }
        return Set(array)
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "RAWMaster.FrozenPresetMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
