{
  description = "Embedded engines for data and AI, built with Nix: DuckDB, chDB, NeuG and zvec";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # the overlay and the checks must also work with the current stable release
    # and the one before it
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-previous.url = "github:NixOS/nixpkgs/nixos-25.11";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";

    # the official Rust toolchain, see nix/overlay.nix
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        ./nix/overlay.nix
        ./nix/lib.nix
        ./nix/nixpkgs.nix
        ./nix/devshell.nix
        ./nix/templates.nix
        # the engines: their packages and checks
        ./nix/duckdb
        ./nix/chdb
        ./nix/zvec
        ./nix/neug
      ];
    };
}
