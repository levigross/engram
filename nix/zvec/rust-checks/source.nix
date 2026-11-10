# The pinned upstream workspace plus local bindings for zvec 0.8.1. Apply the
# same per-crate patches when vendoring the published crates for a consumer.
{ pkgs }:
let
  pin = pkgs.lib.importJSON ./pin.json;
  upstream = pkgs.fetchFromGitHub {
    owner = "zvec-ai";
    repo = "zvec-rust";
    inherit (pin) rev hash;
  };
in
pkgs.runCommand "zvec-rust-${pin.version}-patched-source"
  {
    nativeBuildInputs = [ pkgs.patch ];
    passthru = { inherit upstream; };
  }
  ''
    cp -r ${upstream} $out
    chmod -R u+w $out
    patch --fuzz=0 -d $out/zvec-sys -p1 < ${./sys-api.patch}
    patch --fuzz=0 -d $out/zvec -p1 < ${./safe-api.patch}
  ''
