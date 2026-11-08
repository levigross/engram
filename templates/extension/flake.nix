{
  description = "A DuckDB extension, linked into DuckDB";

  inputs = {
    engram.url = "github:levigross/engram";
    nixpkgs.follows = "engram/nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      engram,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      forAllSystems =
        f:
        lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: f nixpkgs.legacyPackages.${system});

      # nixpkgs' duckdb, with the extensions of engram and `mkExtension`
      duckdbFor = pkgs: engram.lib.duckdb pkgs;

      extensionFor = pkgs: pkgs.callPackage ./extension.nix { duckdb = duckdbFor pkgs; };

      # DuckDB with the extension linked in: no INSTALL, no LOAD
      duckdbWithExtension = pkgs: (duckdbFor pkgs).withExtensions (_: [ (extensionFor pkgs) ]);
    in
    {
      packages = forAllSystems (pkgs: {
        default = duckdbWithExtension pkgs;
      });

      checks = forAllSystems (pkgs: {
        default = pkgs.runCommand "duckdb-hello-check" { } ''
          ${lib.getExe (duckdbWithExtension pkgs)} -no-agent -bail -c ${lib.escapeShellArg (extensionFor pkgs).smoke.sql}
          touch $out
        '';
      });
    };
}
