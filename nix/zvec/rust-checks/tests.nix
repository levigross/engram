# The tests of the crates zvec-rust-sys and zvec-rust, the zvec team's own, run against our
# library (pkgs/zvec-c): the repository of the crates at the tag the crates of crates.io were
# made from, with the lock file it ships (scripts/update-zvec-rust.sh keeps a copy, since a
# build cannot read one from a fetched source, and the check fails if the repository's differs).
#
# What runs is what the team's own CI runs (`cargo test --lib`, `--tests`, `--doc`) for the
# two crates that this repository provides. The workspace has two more members, which are not
# provided: zvec-build (published as zvec-rust-build, a helper for the build script of a
# program that wants the library staged next to it) and zvec-rpath-smoke (a program that tests
# that helper). The benchmarks (criterion) are not built or run: they measure, they test nothing.
#
# Four passes: with the default features of zvec-rust (`bundled`, which only changes what the
# build script of zvec-rust-sys may do when the library is not found) and without them, and with
# the default features and without io_uring (../io), with libaio to be found and without it. The
# test programs are built once and run in each pass.
#
# The original crates target v0.8.0-beta2. Local patches bind the remaining v0.8.1
# functions and add three regressions; the same patched sources run in every mode.
{
  pkgs,
  src,
  testsLockFile,
  # how io_uring is taken away from a program (../io)
  io,
}:

let
  inherit (pkgs) lib zvec-c;
  pin = lib.importJSON ./pin.json;

  # The test targets of zvec-rust, as its manifest lists them (`autotests` is off: a file in
  # tests/ that is not listed is never built). The check compares them with the manifest it is
  # given, so a target that upstream adds is not run unnoticed.
  targets = [
    "collection_close_test"
    "fts_no_vector_test"
    "integration_test"
    "jieba_fts_test"
    "scalar_query_test"
    "string_filter_test"
  ];

  # The tests in the documentation: seven, of which one is marked `ignore` (it shows a
  # `prelude` that needs a collection), five are compiled and not run (`compile`), and one is
  # `compile_fail`, which passes if it does not compile. They are not counted from the sources,
  # which have no marker for them; this is the list that `cargo test --doc` printed.
  doctests = {
    passed = 6;
    ignored = 1;
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "zvec-rust-tests";
  inherit (pin) version;
  inherit src;
  cargoLock.lockFile = testsLockFile;

  auditable = false;
  strictDeps = true;
  nativeBuildInputs = [
    pkgs.jq
    (io.hook [ ])
    (pkgs.makeSetupHook { name = "zvec-rust-tests-hook"; } ./tests.sh)
  ];
  # the linker wrapper puts the directory of the library in the RUNPATH of the test programs,
  # which the build script of zvec-rust-sys does not
  buildInputs = [ zvec-c ];

  env = zvec-c.rustEnv // {
    ZVEC_LIB_DIR = "${zvec-c}/lib";
    # test programs without debug information link faster and are a tenth of the size
    CARGO_PROFILE_DEV_DEBUG = "0";
  };

  inherit testsLockFile;
  testTargets = lib.concatStringsSep " " (lib.sort lib.lessThan targets);
  docPassed = doctests.passed;
  docIgnored = doctests.ignored;
  rustTarget = pkgs.stdenv.hostPlatform.rust.rustcTargetSpec;
  zvecLib = "${zvec-c}/lib";

  dontBuild = true;
  doCheck = true;
  checkPhase = "rustTestsCheck";
  installPhase = ''
    mkdir -p $out
    cp $TMPDIR/logs/* $out/
  '';

  meta = {
    description = "The tests of zvec-rust ${pin.version}, run against libzvec_c_api ${zvec-c.version}";
    platforms = [ "x86_64-linux" ];
  };
}
