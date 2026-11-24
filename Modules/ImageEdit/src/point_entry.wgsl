@compute @workgroup_size(16, 16)
fn run(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy >= params.size) {
        return;
    }
    let i = gid.y * params.size.x + gid.x;
