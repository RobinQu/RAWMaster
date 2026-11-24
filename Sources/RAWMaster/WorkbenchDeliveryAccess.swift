import Foundation
import RAWMasterLibrary

/// Retains the host permission while Rust opens and verifies the frozen directory.
final class WorkbenchDeliveryAccess: Sendable {
    let url: URL
    private let grantedURL: URL
    private let scoped: Bool

    init(_ granted: URL) {
        grantedURL = granted
        scoped = granted.startAccessingSecurityScopedResource()
        url = granted.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    deinit {
        if scoped { grantedURL.stopAccessingSecurityScopedResource() }
    }

    private struct Bookmark: Codable {
        let data: Data
        let securityScoped: Bool
        let catalog: CatalogFile
    }

    private struct CatalogFile: Codable {
        private struct APFS: Codable, Equatable {
            let volumeUUID: String
            let birthSeconds: UInt64
            let birthNanoseconds: UInt32
        }

        private struct DescriptorIdentity: Decodable {
            let device: UInt64
            let inode: UInt64
            let apfs: APFS?
        }

        let device: UInt64
        let inode: UInt64
        let createdAt: Date
        private let apfs: APFS?

        init(_ database: URL) throws {
            let resolved = database.resolvingSymlinksInPath()
            let info = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard info[.type] as? FileAttributeType == .typeRegular,
                  let device = (info[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (info[.systemFileNumber] as? NSNumber)?.uint64Value, inode != 0,
                  let created = info[.creationDate] as? Date else { throw WorkbenchDeliveryIssue.targetOffline }
            let identity = try LibraryEngine.shared().request("workbenchCatalogFile", at: resolved,
                payload: LibraryEmpty(), as: DescriptorIdentity.self)
            guard identity.device == device, identity.inode == inode else { throw WorkbenchDeliveryIssue.targetOffline }
            self.device = device
            self.inode = inode
            self.createdAt = created
            self.apfs = identity.apfs
        }

        func matches(_ current: CatalogFile) -> Bool {
            guard inode == current.inode else { return false }
            if let apfs { return apfs == current.apfs }
            return device == current.device && createdAt == current.createdAt
        }
    }

    private static func key(_ id: String) -> String { "rawmaster.export.delivery.grant." + id }

    static func hasBookmark(grantID: String, in defaults: UserDefaults) -> Bool {
        defaults.data(forKey: key(grantID)) != nil
    }

    /// Bookmarks belong to this host's preferences, outside catalog backups.
    func remember(grantID: String, database: URL, in defaults: UserDefaults) throws {
        let catalog = try CatalogFile(database)
        if let stored = defaults.data(forKey: Self.key(grantID)) {
            guard try JSONDecoder().decode(Bookmark.self, from: stored).catalog.matches(catalog) else {
                throw WorkbenchDeliveryIssue.targetOffline
            }
        }
        let bookmark: Bookmark
        do {
            bookmark = .init(data: try grantedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                securityScoped: true, catalog: catalog)
        } catch {
            bookmark = .init(data: try grantedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
                securityScoped: false, catalog: catalog)
        }
        defaults.set(try JSONEncoder().encode(bookmark), forKey: Self.key(grantID))
    }

    static func open(grantID: String, database: URL, in defaults: UserDefaults) throws -> WorkbenchDeliveryAccess {
        do {
            guard let stored = defaults.data(forKey: key(grantID)) else { throw WorkbenchDeliveryIssue.targetOffline }
            let bookmark = try JSONDecoder().decode(Bookmark.self, from: stored)
            guard try bookmark.catalog.matches(CatalogFile(database)) else { throw WorkbenchDeliveryIssue.targetOffline }
            var stale = false
            let options: URL.BookmarkResolutionOptions = bookmark.securityScoped
                ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
            let url = try URL(resolvingBookmarkData: bookmark.data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw WorkbenchDeliveryIssue.targetOffline }
            let access = WorkbenchDeliveryAccess(url)
            guard !bookmark.securityScoped || access.scoped else { throw WorkbenchDeliveryIssue.targetOffline }
            return access
        } catch {
            throw WorkbenchDeliveryIssue.targetOffline
        }
    }
}
