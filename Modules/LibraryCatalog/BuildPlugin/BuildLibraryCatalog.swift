import Foundation
import PackagePlugin

@main
struct BuildLibraryCatalog: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let root = context.package.directoryURL
        let work = context.pluginWorkDirectoryURL
        let script = root.appendingPathComponent("build-catalog.sh")
        let sources = root.appendingPathComponent("src")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let inputs = (enumerator?.allObjects as? [URL] ?? [])
            .filter { ["rs", "sql"].contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
        let artifact = work.appendingPathComponent("rawmaster-library.runtime")
        return [.buildCommand(
            displayName: "Building RAWMaster library catalog",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, root.path, work.appendingPathComponent("cargo").path, artifact.path],
            inputFiles: [script, root.appendingPathComponent("Cargo.toml"), root.appendingPathComponent("Cargo.lock")] + inputs,
            outputFiles: [artifact]
        )]
    }
}
