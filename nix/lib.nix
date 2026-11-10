# For using this without the overlay: an engine of this flake, built from whichever
# nixpkgs is given.
{ self, ... }:

{
  flake.lib = {
    # DuckDB, with `withExtensions`
    duckdb = pkgs: (pkgs.extend self.overlays.default).duckdb;

    # every pinned DuckDB version, by release ("1.4.3") and by line ("1.4")
    duckdbVersions = pkgs: (pkgs.extend self.overlays.default).duckdbVersions;

    # chDB, ClickHouse in your process: libchdb with its header, and `pythonModule`
    chdb = pkgs: (pkgs.extend self.overlays.default).chdb;

    # NeuG, an embedded graph database: libneug, its headers and extensions
    neug = pkgs: (pkgs.extend self.overlays.default).neug;

    # NeuG's C interface, also used by its Rust bindings
    neug-c = pkgs: (pkgs.extend self.overlays.default).neug-c;

    # zvec, an in-process vector database: its core libraries, as NeuG links them
    zvec = pkgs: (pkgs.extend self.overlays.default).zvec;

    # zvec's C API as a shared library, which its Rust crates (zvec-rust) link
    zvec-c = pkgs: (pkgs.extend self.overlays.default).zvec-c;
  };
}
