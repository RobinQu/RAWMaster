import AppKit
import RAWMasterCore

@MainActor
enum LibraryFolderIcon {
    static let image = Bundle.module.url(forResource: "LibraryFolder", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    static func applyFolderFallback(to package: LocalLibraryPackage) {
        switch package.kind {
        case .working:
            break
        case .legacy:
            // A selected SQLite file may live in a shared folder. Only brand the app's own legacy directory.
            guard package.database.path == AppModel.defaultLibraryURL.path else { return }
        case .backup:
            return
        }
        installDefault(in: package.root)
    }

    private static func installDefault(in directory: URL) {
        // Finder stores a folder's existing custom icon in this file.
        let existingIcon = directory.appendingPathComponent("Icon\r")
        guard let image, FileManager.default.isWritableFile(atPath: directory.path),
              (try? FileManager.default.attributesOfItem(atPath: existingIcon.path)) == nil else { return }
        _ = NSWorkspace.shared.setIcon(image, forFile: directory.path, options: [])
    }
}
