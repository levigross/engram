_:

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
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.zvec-c) (
          lib.mapAttrs' (name: check: lib.nameValuePair "zvec-rust-${name}" check) (
            import ./rust-checks { pkgs = nixpkgs; }
          )
        )
      );
    };
}
