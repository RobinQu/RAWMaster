use std::{env, fs, path::PathBuf};

fn main() {
    if env::var_os("CARGO_FEATURE_METAL_SURFACE").is_some()
        && env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos")
    {
        let mut objc = cc::Build::new();
        if env::var_os("CARGO_FEATURE_NATIVE_HALF_PROBE").is_some() {
            objc.define("RM_IMAGE_NATIVE_HALF_PROBE", None);
        }
        objc.file("src/metal_surface_identity.m")
            .flag("-fobjc-arc")
            .compile("rm_surface_identity");
        for framework in ["Foundation", "Metal", "IOSurface", "CoreVideo"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rerun-if-changed=src/metal_surface_identity.m");
    }
    if env::var_os("CARGO_FEATURE_SURFACE_FENCE_PROBE").is_some()
        && env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos")
    {
        cc::Build::new()
            .file("tests/metal_surface/native.m")
            .flag("-fobjc-arc")
            .compile("rm_surface_replay_host");
        for framework in ["CoreImage", "CoreGraphics"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rerun-if-changed=tests/metal_surface/native.m");
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let read = |name: &str| {
        let path = format!("shaders/{name}.ci.metal");
        println!("cargo:rerun-if-changed={path}");
        fs::read_to_string(&path).unwrap_or_else(|err| panic!("{path}: {err}"))
    };
    let parts = [
        ("// RM_MASK_GEOMETRY", read("mask_geometry")),
        ("// RM_MASK_GRAIN_TRANSFER", read("mask_grain_transfer")),
        ("// RM_COLOR_GRAIN_LATTICE", read("color_grain_lattice")),
    ];
    for name in ["mask", "mask_analytic"] {
        let mut assembled = String::new();
        for line in read(name).lines() {
            match parts.iter().find(|(marker, _)| line.trim() == *marker) {
                Some((_, code)) => assembled.push_str(code),
                None => assembled.push_str(line),
            }
            assembled.push('\n');
        }
        fs::write(output.join(format!("{name}.ci.metal")), assembled).unwrap();
    }
    println!("cargo:rerun-if-changed=src/reference.cpp");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .flag_if_supported("-ffp-contract=off")
        .file("src/reference.cpp")
        .compile("rm_image_reference");
}
