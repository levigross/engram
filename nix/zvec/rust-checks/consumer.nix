# The Rust example of zvec (examples/zvec-rust-consumer): a program that uses the crate zvec-rust
# and links libzvec_c_api.so from zvec-c. The crate's default feature `bundled` would have its
# build script download a library or build zvec, so the example turns it off, and the build sets
# ZVEC_AUTO_BUILD=0 as well.
{
  lib,
  rustPlatform,
  zvec-c,
}:

let
  policy = import ./policy.nix { inherit lib; };

  example = ../../../examples/zvec-rust-consumer;
  lockFile = example + "/Cargo.lock";
  # fails if the lock file has a crate of TLS or HTTP, or one from git
  lock = policy.assertClean "examples/zvec-rust-consumer/Cargo.lock" (builtins.readFile lockFile);
in
lib.seq lock (
  rustPlatform.buildRustPackage {
    pname = "zvec-rust-consumer";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = example;
      fileset = lib.fileset.unions [
        (example + "/Cargo.toml")
        lockFile
        (example + "/src")
      ];
    };
    cargoLock = { inherit lockFile; };

    strictDeps = true;
    # for the library: the linker wrapper puts its directory in the RUNPATH, which the build
    # script of zvec-rust-sys does not
    buildInputs = [ zvec-c ];

    env = zvec-c.rustEnv // {
      ZVEC_LIB_DIR = "${zvec-c}/lib";
      ZVEC_INCLUDE_DIR = "${zvec-c}/include";
    };

    doCheck = true;
  }
)
