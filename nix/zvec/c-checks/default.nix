# What must work with zvec's C API library (pkgs/zvec-c): what it is made of and exports, the
# repair of the headers, how it does its I/O where the kernel has no io_uring, and zvec's own
# tests and examples of the C API. Each check is a file next to this one.
{ pkgs }:

let
  io = import ../io { inherit pkgs; };
in
{
  params = import ./params.nix { inherit pkgs; };
  library = import ./library.nix { inherit pkgs; };
  io-backends = import ./io-backends.nix { inherit pkgs io; };
  tests = import ./tests.nix { inherit pkgs io; };
  examples = import ./examples.nix { inherit pkgs io; };
  core-tests = import ./core-tests.nix { inherit pkgs io; };
  db-tests = import ./db-tests.nix { inherit pkgs io; };
}
