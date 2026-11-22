import RMCatalogProbe

precondition(CommandLine.arguments.count == 2)
let path = CommandLine.arguments[1]
precondition(rm_probe_count_v1(nil, 0) == -1)
for rating: Int32 in [0, 4] {
    let count = path.withCString { rm_probe_count_v1($0, rating) }
    precondition(count >= 0)
    print(count)
}
