# zvec's own test of the C API (tests/c/c_api_test.c, with utils.c), compiled against the
# installed library the way an application is (the header of the package, -lzvec_c_api, no path to
# the library but the one the linker records) with upstream's flags: gnu99 and the strict
# warnings of cc_test (tests/c/CMakeLists.txt, cmake/bazel.cmake). It is run in every mode of the
# I/O, as the machine has it and without io_uring (../io), and has to pass in all.
#
# The test is a framework of its own that returns 0 only if every function that main calls
# passed. The check also reads those functions from the source and requires exactly them to have
# run, by name, so that a program cannot pass by running too few.
{ pkgs, io }:

let
  inherit (pkgs) zvec-c;
in
pkgs.stdenv.mkDerivation {
  pname = "zvec-c-tests";
  inherit (zvec-c) version;
  strictDeps = true;
  __structuredAttrs = true;
  nativeBuildInputs = [
    pkgs.patchelf
    (io.hook [ ])
  ];
  buildCommandPath = ./tests.sh;

  zvecC = zvec-c;
  tests = "${zvec-c.src}/tests/c";
}
