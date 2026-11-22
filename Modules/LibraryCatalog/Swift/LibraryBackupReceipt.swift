import Foundation

/// The saved package location is local to this device. Coverage itself is rechecked against the sealed manifest.
public struct LibraryBackupReceipt: Codable, Sendable {
    public let libraryID: String
    public let generation: String
    public let package: URL
    public let manifestSHA256: String
    public let verifiedAt: Date

    static func key(_ database: URL) -> String { "library.fullBackup." + database.standardizedFileURL.path }

    public static func latest(for database: URL, defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key(database)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(for database: URL, defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key(database))
    }
}
