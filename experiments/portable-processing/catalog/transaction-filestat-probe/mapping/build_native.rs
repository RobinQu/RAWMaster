use std::{env, path::PathBuf, process::Command};
fn main() {
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let obj = out.join("witness.o");
    let lib = out.join("librm_natural_map.a");
    assert!(Command::new("cc")
        .args([
            "-std=c11",
            "-O2",
            "-D_GNU_SOURCE",
            "-c",
            "witness-vfs.c",
            "-o"
        ])
        .arg(&obj)
        .status()
        .unwrap()
        .success());
    assert!(Command::new("ar")
        .args(["rcs"])
        .arg(lib)
        .arg(obj)
        .status()
        .unwrap()
        .success());
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=rm_natural_map");
    println!("cargo:rerun-if-changed=witness-vfs.c");
}
