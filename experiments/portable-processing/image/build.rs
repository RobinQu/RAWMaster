fn main() {
    println!("cargo:rerun-if-changed=src/reference.cpp");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .flag_if_supported("-ffp-contract=off")
        .file("src/reference.cpp")
        .compile("rmi_reference");
}
