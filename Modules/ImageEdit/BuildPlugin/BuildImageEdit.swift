import Foundation
import PackagePlugin

@main
struct BuildImageEdit: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let root = context.package.directoryURL
        let work = context.pluginWorkDirectoryURL
        let script = root.appendingPathComponent("build-image.sh")
        let files = ["src", "shaders", "include"].flatMap { directory -> [URL] in
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter {
                ["rs", "wgsl", "cpp", "c", "h", "m", "metal"].contains($0.pathExtension)
            }
        }
        let artifact = work.appendingPathComponent("rawmaster-image.runtime")
        return [.buildCommand(
            displayName: "Build the RAWMaster image core",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, root.path, work.appendingPathComponent("cargo").path, artifact.path],
            inputFiles: [script, root.appendingPathComponent("Cargo.toml"), root.appendingPathComponent("Cargo.lock"),
                         root.appendingPathComponent("build.rs")] + files.sorted { $0.path < $1.path },
            outputFiles: [artifact]
        )]
    }
}
