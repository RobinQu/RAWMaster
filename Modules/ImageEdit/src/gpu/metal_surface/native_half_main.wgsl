fn native_point(p: vec2<u32>) -> vec4<f32> {
    let actual = vec2<u32>(p.x, params.size.y - 1u - p.y);
    let source = textureLoad(half_source, actual, 0);
    if !opaque_finite(source) { return invalid_pixel(); }
    return half_point_graph(source, p);
}
@compute @workgroup_size(8,8)
fn native_band(@builtin(global_invocation_id) id:vec3<u32>, @builtin(local_invocation_index) lane:u32,
               @builtin(workgroup_id) group:vec3<u32>, @builtin(num_workgroups) groups:vec3<u32>) {
    start_receipt(lane);
    var count = 0u;
    let rows = min(256u, params.size.y-params.band_y);
    if id.x < params.size.x && id.y < rows {
        let value = native_point(id.xy + vec2<u32>(0u,params.band_y));
        textureStore(half_target,id.xy,value);
        count = select(0u,1u,opaque_finite(value));
    }
    finish_receipt(lane,group.y*groups.x+group.x,count);
}
@compute @workgroup_size(8,8)
fn direct_half(@builtin(global_invocation_id) id:vec3<u32>, @builtin(local_invocation_index) lane:u32,
               @builtin(workgroup_id) group:vec3<u32>, @builtin(num_workgroups) groups:vec3<u32>) {
    start_receipt(lane);
    var count = 0u;
    let rows = min(256u, params.size.y-params.band_y);
    if id.x < params.size.x/2u && id.y < rows/2u {
        let p = 2u*id.xy+vec2<u32>(0u,params.band_y);
        let a=native_point(p); let b=native_point(p+vec2<u32>(1,0));
        let c=native_point(p+vec2<u32>(0,1)); let d=native_point(p+vec2<u32>(1,1));
        if opaque_finite(a) && opaque_finite(b) && opaque_finite(c) && opaque_finite(d) {
            var value = mix(mix(a,b,0.5),mix(c,d,0.5),0.5);
            if params.mode==1u { value=((a+b)*0.5+(c+d)*0.5)*0.5; }
            if params.mode==2u { value=((a+c)*0.5+(b+d)*0.5)*0.5; }
            if opaque_finite(value) {
                textureStore(half_target,id.xy+vec2<u32>(0u,params.band_y/2u),value);
                count=4u;
            }
        }
    }
    finish_receipt(lane,group.y*groups.x+group.x,count);
}
@compute @workgroup_size(8,8)
fn sampled_half(@builtin(global_invocation_id) id:vec3<u32>, @builtin(local_invocation_index) lane:u32,
                @builtin(workgroup_id) group:vec3<u32>, @builtin(num_workgroups) groups:vec3<u32>) {
    start_receipt(lane);
    var count=0u;
    let rows=min(256u,params.size.y-params.band_y);
    if id.x < params.size.x/2u && id.y < rows/2u {
        let p=2u*id.xy;
        let uv=vec2<f32>(p+vec2<u32>(1u))/vec2<f32>(textureDimensions(half_source));
        let value=textureSampleLevel(half_source,linear_sampler,uv,0.0);
        if opaque_finite(value) {
            textureStore(half_target,id.xy+vec2<u32>(0u,params.band_y/2u),value);
            count=4u;
        }
    }
    let native_slots=((params.size.x+7u)/8u)*((rows+7u)/8u);
    finish_receipt(lane,native_slots+group.y*groups.x+group.x,count);
}
