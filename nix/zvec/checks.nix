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
        lib.concatMapAttrs
          (
            prefix:
            { package, dir }:
            lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.${package}) (
              lib.mapAttrs' (name: check: lib.nameValuePair "${prefix}-${name}" check) (
                import dir { pkgs = nixpkgs; }
              )
            )
          )
          {
            zvec = {
              package = "zvec";
              dir = ./checks;
            };
            zvec-c = {
              package = "zvec-c";
              dir = ./c-checks;
            };
            zvec-rust = {
              package = "zvec-c";
              dir = ./rust-checks;
            };
          }
      );
    };
}
