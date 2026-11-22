import Foundation
import RAWMasterCore

// The runner supplies a private SQLite backup. LibraryStore opens that copy normally.
struct ProjectionRow: Codable {
    let assetID: String
    let filename: String
    let camera: String?
    let captured: Double?
    let rating: Int
}

struct QueryCase: Codable {
    let name: String
    let camera: String?
    let since: Double?
    let minimumRating: Int?
    let needle: String?
    let ids: [String]
    let warmMilliseconds: [Double]
}

struct PrivateFixture: Codable {
    let catalogFiles: Int
    let admissions: Int
    let groups: Int
    let catalogOpenMilliseconds: Double
    let firstSnapshotMilliseconds: Double
    let subsequentSnapshotMilliseconds: [Double]
    let rows: [ProjectionRow]
    let cases: [QueryCase]
}

func milliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

func folded(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX"))
}

@main struct CatalogBaseline {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let url = URL(fileURLWithPath: args[1])
        // Only accept the scratch layout produced by the companion runner.
        guard url.lastPathComponent == "source-backup.sqlite",
              FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
        let (store, openMS) = try milliseconds { try LibraryStore(databaseURL: url) }
        let (initial, firstMS) = try milliseconds { try LibrarySnapshot.read(store: store, groupingSessionID: nil) }
        var snapshots: [Double] = []
        for _ in 0..<9 {
            let (count, ms) = try milliseconds { try LibrarySnapshot.read(store: store, groupingSessionID: nil).assets.count }
            precondition(count == initial.assets.count)
            snapshots.append(ms)
        }
        let admitted = Set(initial.admissions.map(\.assetID))
        let assets = initial.assets.filter { admitted.contains($0.id) }
        precondition(!assets.isEmpty && assets.count == admitted.count)
        let reviews = Set(initial.reviewRecords.filter(\.reviewed).map(\.assetID))
        let rows = assets.map { asset in
            ProjectionRow(assetID: asset.id, filename: folded(asset.filename),
                camera: asset.camera.map(AssetSearchEngine.cameraKey),
                captured: asset.capturedAt?.timeIntervalSince1970, rating: asset.rating)
        }
        let dates = assets.compactMap(\.capturedAt).sorted()
        guard let camera = assets.compactMap(\.camera).sorted().first, !dates.isEmpty else {
            throw CocoaError(.coderValueNotFound)
        }
        let since = dates[dates.count / 2]
        let sample = assets[assets.count / 2].filename
        let needle = URL(fileURLWithPath: sample).deletingPathExtension().lastPathComponent.suffix(3)
        let inputs: [(String, ProjectSearchQuery)] = [
            ("all", .init()),
            ("camera_since_median", .init(capturedFrom: since, camera: camera)),
            ("rating_four_plus", .init(minimumRating: 4)),
            ("filename_substring", .init(filename: String(needle)))
        ]
        let cases = try inputs.map { name, query in
            func search() throws -> [AssetRecord] {
                try AssetSearchEngine.filter(assets: assets, query: query, tags: initial.assetTags,
                    reviewedIDs: reviews, sort: .capturedDescending, colorLabels: initial.assetColorLabels)
            }
            let expected = try search().map(\.id)
            var times: [Double] = []
            for _ in 0..<31 {
                let (matches, ms) = try milliseconds { try search() }
                precondition(matches.map(\.id) == expected)
                times.append(ms)
            }
            return QueryCase(name: name, camera: query.camera.map(AssetSearchEngine.cameraKey),
                since: query.capturedFrom?.timeIntervalSince1970, minimumRating: query.minimumRating,
                needle: query.filename.isEmpty ? nil : folded(query.filename), ids: expected, warmMilliseconds: times)
        }
        let result = PrivateFixture(catalogFiles: initial.assets.count, admissions: assets.count,
            groups: initial.groups.count, catalogOpenMilliseconds: openMS, firstSnapshotMilliseconds: firstMS,
            subsequentSnapshotMilliseconds: snapshots, rows: rows, cases: cases)
        try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: args[2]), options: .withoutOverwriting)
    }
}
