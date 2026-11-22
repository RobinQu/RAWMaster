import Foundation

public final class OpenLibraryLocation: @unchecked Sendable {
    public let database: URL
    private let accessedRoot: URL?
    init(database: URL, accessedRoot: URL? = nil) {
        self.database = database
        self.accessedRoot = accessedRoot
    }
    deinit {
        #if os(macOS)
        accessedRoot?.stopAccessingSecurityScopedResource()
        #endif
    }
}

/// The default location stays implicit. Only an explicitly selected library is persisted.
public enum LibraryLocation {
    private struct Selection: Codable {
        var root: URL
        var filename: String
        var bookmark: Data?
    }
    private static let key = "library.activeLocation.v1"

    public static func resolve(defaultURL: URL, defaults: UserDefaults) throws -> OpenLibraryLocation {
        guard let data = defaults.data(forKey: key) else { return OpenLibraryLocation(database: defaultURL) }
        let selection = try JSONDecoder().decode(Selection.self, from: data)
        guard selection.filename == URL(fileURLWithPath: selection.filename).lastPathComponent,
              !selection.filename.isEmpty, ![".", ".."].contains(selection.filename) else {
            throw LibraryEngineError("资料库文件位置无效")
        }
        var root = selection.root
        var access: URL?
        #if os(macOS)
        if let bookmark = selection.bookmark {
            var stale = false
            root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
            if root.startAccessingSecurityScopedResource() { access = root }
        }
        #endif
        let resolved = OpenLibraryLocation(database: root.appendingPathComponent(selection.filename), accessedRoot: access)
        guard FileManager.default.fileExists(atPath: resolved.database.path) else {
            throw LibraryEngineError("找不到已选择的资料库。请连接原磁盘或打开其他资料库。")
        }
        return resolved
    }

    public static func remember(_ database: URL, defaults: UserDefaults) throws {
        let root = database.deletingLastPathComponent()
        var bookmark: Data?
        #if os(macOS)
        bookmark = try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        let selection = Selection(root: root, filename: database.lastPathComponent, bookmark: bookmark)
        defaults.set(try JSONEncoder().encode(selection), forKey: key)
    }

    public static func useDefault(defaults: UserDefaults) { defaults.removeObject(forKey: key) }
}
