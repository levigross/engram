# The examples of zvec's C API (examples/c), compiled against the installed library the way an
# application is (the header of the package, -lzvec_c_api, no path to the library but the one the
# linker records) and run, in every mode of the I/O: as the machine has it and without io_uring
# (../io). Upstream builds them as a CMake project of its own, as C99 with threads and libdl; its
# workflows run six of the seven (diskann_example is not among them).
#
# doc_example filters its query with 'string_field_0' where its documents have 'test_string_0',
# so that query returns nothing and the loop over its results checks nothing: that is in the
# example, not in the library (the test of the C API checks what a filter returns).
{ pkgs, io }:

let
  inherit (pkgs) zvec-c;
in
pkgs.stdenv.mkDerivation {
  pname = "zvec-c-examples";
  inherit (zvec-c) version;
  strictDeps = true;
  __structuredAttrs = true;
  nativeBuildInputs = [
    pkgs.patchelf
    (io.hook [ ])
  ];
  buildCommandPath = ./examples.sh;

  zvecC = zvec-c;
  examples = "${zvec-c.src}/examples/c";
  # the sources of examples/c; the check fails if upstream adds one
  names = [
    "basic_example"
    "collection_schema_example"
    "diskann_example"
    "doc_example"
    "field_schema_example"
    "index_example"
    "optimized_example"
  ];
}
