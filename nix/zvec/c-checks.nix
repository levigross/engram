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
          lib.mapAttrs' (name: check: lib.nameValuePair "zvec-c-${name}" check) (
            import ./c-checks { pkgs = nixpkgs; }
          )
        )
      );
    };
}
