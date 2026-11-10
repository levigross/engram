//! Links libneug_c.so, the C interface of NeuG, which is built elsewhere (the package neug-c of
//! this repository). Nothing is built or downloaded here: the directory with the library is
//! named by NEUG_LIB_DIR, and, when NEUG_INCLUDE_DIR names the directory with neug_c.h, the
//! version of the interface in it must be the one these declarations are of.

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::exit;

/// The NEUG_C_ABI_VERSION that src/lib.rs declares.
const ABI_VERSION: u32 = 1;

fn fail(message: &str) -> ! {
    eprintln!("neug-sys: {message}");
    exit(1);
}

fn main() {
    println!("cargo:rerun-if-env-changed=NEUG_LIB_DIR");
    println!("cargo:rerun-if-env-changed=NEUG_INCLUDE_DIR");

    let Some(lib_dir) = env::var_os("NEUG_LIB_DIR").map(PathBuf::from) else {
        fail(
            "NEUG_LIB_DIR is not set: it names the directory with libneug_c.so, which the package \
             neug-c builds. Nothing is built or downloaded here.",
        );
    };
    let library = if cfg!(target_os = "macos") {
        "libneug_c.dylib"
    } else {
        "libneug_c.so"
    };
    if !lib_dir.join(library).exists() {
        fail(&format!("{} has no {library}", lib_dir.display()));
    }

    if let Some(include_dir) = env::var_os("NEUG_INCLUDE_DIR").map(PathBuf::from) {
        let header = include_dir.join("neug_c.h");
        println!("cargo:rerun-if-changed={}", header.display());
        let text = fs::read_to_string(&header)
            .unwrap_or_else(|e| fail(&format!("cannot read {}: {e}", header.display())));
        let declared = text
            .lines()
            .find_map(|line| line.strip_prefix("#define NEUG_C_ABI_VERSION "))
            .and_then(|number| number.trim().parse::<u32>().ok())
            .unwrap_or_else(|| fail(&format!("{} has no NEUG_C_ABI_VERSION", header.display())));
        if declared != ABI_VERSION {
            fail(&format!(
                "{} is of version {declared} of the interface, these declarations are of \
                 version {ABI_VERSION}",
                header.display()
            ));
        }
    }

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=neug_c");
}
