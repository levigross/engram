# Keep the lightweight CI shell separate from native Rust development shells.
{ inputs, ... }:

{
  perSystem =
    {
      pkgs,
      system,
      lib,
      ...
    }:
    let
      rust = import ./rust-toolchain.nix { inherit inputs pkgs; };
      neug = import ./neug/rust.nix {
        inherit pkgs;
        inherit (rust) craneLib;
      };
    in
    {
      devShells = {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.actionlint
            pkgs.deadnix
            pkgs.nixfmt
            pkgs.shellcheck
            pkgs.statix
          ];
        };
        rust = rust.craneLib.devShell {
          packages = [
            pkgs.pkg-config
          ];
        };
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        rust-neug = rust.craneLib.devShell (
          {
            inherit (neug) checks;
            packages = [
              pkgs.pkg-config
            ];
          }
          // neug.environment
        );
      };
    };
}
