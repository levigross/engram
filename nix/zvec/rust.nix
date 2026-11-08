# The Rust example of zvec (examples/zvec-rust-consumer), which uses the crate zvec-rust of
# crates.io: the bindings of the C API that the zvec team publishes. They link
# libzvec_c_api.so (the package zvec-c), so the database runs in the process of the program.
#
# Their default feature `bundled` makes the build script of zvec-rust-sys download a library
# (with curl, and no check of what it gets) or clone zvec and build it, whenever the directory
# in ZVEC_LIB_DIR does not have the library. The example turns the feature off, and the build
# sets ZVEC_AUTO_BUILD=0 as well, so that a mistake in that directory is an error of the linker
# and not a download.
#
# Nothing in the lock file needs TLS or HTTP (nix/zvec/rust-policy.nix says what it may have),
# and `tls` is the choice the Rust programs of this repository have, made here so that the day
# one does, it is made the same way as for chDB (nix/chdb/rust.nix):
#   "none"     the lock file has no crate of TLS at all (what it is)
#   "rustls"   the lock file has no openssl-sys or native-tls
#   "openssl"  OpenSSL and pkg-config are given to the build
{ pkgs }:

let
  inherit (pkgs) lib zvec-c;
  policy = import ./rust-policy.nix { inherit lib; };

  example = ../../examples/zvec-rust-consumer;
  lockFile = example + "/Cargo.lock";
  lock = policy.assertClean "examples/zvec-rust-consumer/Cargo.lock" (builtins.readFile lockFile);

  program =
    {
      tls ? "none",
    }:
    assert lib.assertMsg (lib.elem tls [
      "none"
      "openssl"
      "rustls"
    ]) "tls is none, openssl or rustls";
    assert lib.assertMsg (
      tls != "none" || (policy.problems lock == [ ])
    ) "tls = none, and the lock file has a crate of TLS";
    pkgs.rustPlatform.buildRustPackage {
      pname = "zvec-rust-consumer";
      version = "0.1.0";

      src = lib.fileset.toSource {
        root = example;
        fileset = example;
      };
      cargoLock.lockFile = lockFile;

      strictDeps = true;
      nativeBuildInputs = lib.optional (tls == "openssl") pkgs.pkg-config;
      # zvec-c is here for its library: the linker wrapper puts its directory in the RUNPATH of
      # the program, which the build script of zvec-rust-sys does not (the program would not
      # find libzvec_c_api.so at run time)
      buildInputs = [ zvec-c ] ++ lib.optional (tls == "openssl") pkgs.openssl;

      env = zvec-c.rustEnv // {
        ZVEC_LIB_DIR = "${zvec-c}/lib";
        ZVEC_INCLUDE_DIR = "${zvec-c}/include";
      };

      doCheck = true;
    };
in
{
  inherit program;
}
