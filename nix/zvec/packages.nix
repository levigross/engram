_:

{
  perSystem =
    {
      lib,
      forEachNixpkgs,
      ...
    }:
    {
      packages = forEachNixpkgs (
        nixpkgs:
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.zvec) {
          inherit (nixpkgs) zvec;
        }
        // lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.zvec-c) {
          inherit (nixpkgs) zvec-c;
          python3-zvec = nixpkgs.zvec-c.pythonModule nixpkgs.python3Packages;

          # Development only: stop after CMake has configured
          dev-configure-zvec-c = nixpkgs.zvec-c.overrideAttrs {
            dontBuild = true;
            dontFixup = true;
            installPhase = "touch $out";
          };

          # Development only: build everything and keep going past failures, to see every
          # error of a build at once
          dev-keep-going-zvec-c = nixpkgs.zvec-c.overrideAttrs {
            ninjaFlags = [
              "-k"
              "0"
              "zvec_c_api"
            ];
          };
        }
      );
    };
}
