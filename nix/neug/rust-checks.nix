{ inputs, ... }:

{
  perSystem =
    {
      lib,
      forEachNixpkgs,
      ...
    }:
    {
      checks = forEachNixpkgs (
        nixpkgs:
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.neug) (
          lib.mapAttrs' (name: check: lib.nameValuePair "neug-${name}" check) (
            import ./rust-checks {
              pkgs = nixpkgs;
              inherit
                (import ../rust-toolchain.nix {
                  inherit inputs;
                  pkgs = nixpkgs;
                })
                craneLib
                ;
            }
          )
        )
      );
    };
}
