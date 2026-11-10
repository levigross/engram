# Cargo builds and development use the same pinned compiler and tools.
{ inputs, pkgs }:

let
  toolchain = pkgs.rust-bin.stable."1.99.1".minimal.override {
    extensions = [
      "clippy"
      "rustfmt"
      "rust-src"
      "rust-analyzer"
    ];
  };
in
{
  inherit toolchain;
  craneLib = (inputs.crane.mkLib pkgs).overrideToolchain toolchain;
}
