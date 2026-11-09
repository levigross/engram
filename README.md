# engram

Embedded engines for data and AI, built with Nix: databases that run inside your process.
Each is built from source, or is a binary pinned by hash, and nothing is fetched when your program runs.

| Engine | What it is | Use it from | Page |
|---|---|---|---|
| DuckDB | Analytical SQL (2.0.0, 1.5.2, 1.4.3), with the extensions that are not in DuckDB's tree linked in | CLI, `libduckdb`, Python, Rust | [DuckDB](docs/duckdb.md) |
| chDB | ClickHouse as a library (prebuilt binary, pinned by hash) | C, Python, Rust | [chDB](docs/chdb.md) |
| NeuG | Graph database (Cypher) 0.3.0, with its six extensions | C++, C, Rust, Python, Node.js | [NeuG](docs/neug.md) |
| zvec | Vector database: a C library at v0.8.1 and the zvec team's Rust crates | C, Rust (C++ static libraries for NeuG) | [zvec](docs/zvec.md) |

## Try it

```sh
nix build github:levigross/engram#duckdb-all      # DuckDB with every extension it can link
nix build github:levigross/engram#chdb            # libchdb and its header
nix build github:levigross/engram#python3-chdb    # the Python module of chDB
nix build github:levigross/engram#neug            # libneug and its six extensions
nix build github:levigross/engram#zvec-c          # zvec's C API library and its header
nix flake show github:levigross/engram            # everything there is
```

Packages are offered for three nixpkgs: unstable under its own name, 26.05 with the prefix
`stable-` and 25.11 with `previous-` (`#stable-chdb`, `#previous-duckdb-all`). A package that a nixpkgs cannot
build is not offered there.

## Use it from your flake

`lib.<engine>` takes your package set and gives the engine, built with it, without changing anything
else in `pkgs`:

```nix
{
  inputs.engines.url = "github:levigross/engram";
  outputs = { engines, nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
      packages.x86_64-linux.default = engines.lib.chdb pkgs;   # or engines.lib.duckdb pkgs
    };
}
```

`overlays.default` adds `duckdb` (replacing nixpkgs' one), `duckdbVersions`, `chdb`, `neug`, `neug-c`,
`zvec` and `zvec-c`. Replacing `duckdb` has a cost, described in
[the DuckDB page](docs/duckdb.md#as-an-overlay).

## What has been checked

- Each engine was built on all three nixpkgs and its checks run, with the upstream's own test suites
  wherever that is possible. A few checks run on fewer (NeuG's Python module is not offered on 25.11);
  the engine's page and the [TODO](docs/TODO.md) say which.
- Every check has something that must fail. What each check proves, and what it leaves out and
  why, is on the engine's page under *Checks*.
- Built and checked on **x86_64-linux with glibc only**. The flake also lists aarch64-linux and
  aarch64-darwin; they are untried.
- "Not built" means nothing was run, not that it fails. Everything that is not done or not known
  is in the [TODO](docs/TODO.md).

## Documentation

| Page | What is in it |
|---|---|
| [DuckDB](docs/duckdb.md), [chDB](docs/chdb.md), [NeuG](docs/neug.md), [zvec](docs/zvec.md) | How to get and use each engine, what to watch out for, and (for maintainers) how it is built and checked |
| [TODO](docs/TODO.md) | What is not done, not known or not fixed, for all engines |
| [Packaging](docs/packaging.md) | A glossary, how an engine is packaged, how to update a pin, checks, CI, adding an engine |

## License

[Apache-2.0](LICENSE) for the Nix code and scripts in this repository. The engines, their
extensions and the crates are not part of it and keep their own licenses: DuckDB MIT,
chDB, ClickHouse, NeuG and zvec Apache-2.0.

---

The repository was `levigross/duckdb-nix` until it held more than DuckDB. GitHub redirects the old
address for as long as nobody else takes the name. Every attribute, `lib.duckdb` and the overlay are
unchanged.
