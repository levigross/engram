# zvec's part of the overlay: `zvec` (the static core libraries) and `zvec-c` (the C API
# library), which nixpkgs does not have.
final: _prev: {
  zvec = final.callPackage ../../pkgs/zvec { };
  zvec-c = final.callPackage ../../pkgs/zvec-c { };
}
