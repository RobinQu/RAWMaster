import Foundation
import PackagePlugin

@main
struct BuildPhotoExport: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let root = context.package.directoryURL
        let work = context.pluginWorkDirectoryURL
        let script = root.appendingPathComponent("build-rust.sh")
        let sources = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("src"),
                                                                  includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "rs" }.sorted { $0.path < $1.path }
        let artifact = work.appendingPathComponent("rawmaster-photo-export.runtime")
        return [.buildCommand(
            displayName: "Build the RAWMaster photo export library",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, root.path, work.appendingPathComponent("cargo").path, artifact.path],
            inputFiles: [script, root.appendingPathComponent("Cargo.toml"), root.appendingPathComponent("Cargo.lock"),
                         root.appendingPathComponent("profiles/srgb.icc")] + sources,
            outputFiles: [artifact]
        )]
    }
}
