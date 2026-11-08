# Which I/O the library uses when the kernel has no io_uring, and that no-iouring (../io) does
# what it says: by the library's own account of its backend (zvec_get_io_backend_type), for each
# error the kernel gives (ENOSYS, EPERM) with libaio on the library path or not. The other checks
# run the tests and examples of zvec in these modes.
{ pkgs, io }:

pkgs.stdenv.mkDerivation {
  name = "zvec-c-io-backends";
  strictDeps = true;
  nativeBuildInputs = [ (io.hook [ ]) ];
  buildCommandPath = ./io-backends.sh;
}
