# engram

Embedded engines for data and AI, built with Nix. The repository was `levigross/duckdb-nix`
until it held more than DuckDB; GitHub redirects the old address (for as long as nobody else
takes the name), and every attribute, `lib.duckdb` and the overlay are unchanged.

Databases that run inside your process, packaged so that a Nix build gets them whole:
built from source, or a binary pinned by hash, and nothing fetched when the program runs.
For each engine the aim is the library, a Python module and a Rust program that links it,
built and checked on three nixpkgs. Each engine's page says which of them are, and which are
not.

| Engine | What it is | How it is provided | For | Details |
|---|---|---|---|---|
| DuckDB | analytical SQL | built from source (2.0.0, 1.5.2, 1.4.3), with the extensions that are not in DuckDB's tree linked in | CLI, `libduckdb`, Python, Rust | [docs/duckdb.md](docs/duckdb.md) |
| chDB | ClickHouse as a library | the upstream's prebuilt `libchdb` and Python wheels, pinned by hash. They are not signed | C (its C++ header does not link), Python, Rust | [docs/chdb.md](docs/chdb.md) |
| NeuG | graph database (Cypher) | built from source (0.3.0), with its six extensions, which `LOAD` finds in the package. Its service mode runs on cpp-httplib instead of brpc, which crashed in a Python process | C++, a C interface and Rust crates (this repository's), Python, Node.js | [docs/neug.md](docs/neug.md) |
| zvec | vector database | built from source, in two packages: the core libraries as NeuG's `vector_search` links them, and the C API library at v0.8.1. The Rust crates are the zvec team's own, pinned by hash | C++ (static), a C library, Rust | [docs/zvec.md](docs/zvec.md) |

Only x86_64-linux with glibc has been built.

## Using it

```sh
nix build github:levigross/engram#duckdb-all      # DuckDB with every extension it can link
nix build github:levigross/engram#chdb            # libchdb and its header
nix build github:levigross/engram#python3-chdb    # the Python module of chDB
nix build github:levigross/engram#neug            # libneug and its six extensions
nix build github:levigross/engram#zvec-c          # zvec's C API library and its header
nix flake show github:levigross/engram            # everything there is
```

Packages are offered for three nixpkgs: unstable under its own name, 26.05 with the prefix
`stable-` and 25.11 with `previous-` (`#stable-chdb`, `#previous-duckdb-all`). A package that
a nixpkgs cannot build is not offered there. Being offered is not being built: DuckDB and
chDB, NeuG and zvec were built and checked on all three, with their test suites, except the
Python module of NeuG, which 25.11 cannot build and is not offered on (see its page). That
includes the unit tests of zvec for its C library: 153 programs of its core libraries and 74 of
its database layer. One of them fails now and then on its first run and is run again when it
does (see [its page](docs/zvec.md#a-test-that-fails-on-its-first-run)).

From your own flake, `lib.<engine>` takes your package set and gives the engine, built
with it, without changing anything else in `pkgs`:

```nix
{
  inputs.engines.url = "github:levigross/engram";
  outputs = { engines, nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
      packages.x86_64-linux.default = engines.lib.chdb pkgs;   # or engines.lib.duckdb pkgs
    };
}
```

`overlays.default` adds `duckdb` (replacing nixpkgs' one), `duckdbVersions`, `chdb`, `neug`,
`neug-c`, `zvec` and `zvec-c`.
Replacing `duckdb` has a cost, described in [the DuckDB page](docs/duckdb.md#as-an-overlay).

## How an engine is packaged

The same things for each, whatever the engine is:

- `pkgs/<engine>`: the package. What it fetches is pinned with a hash that a script
  (`scripts/update-<engine>.sh`) computes from the files themselves, and compares with
  what the upstream publishes where it publishes anything.
- `nix/<engine>`: the overlay, the packages and the checks of the flake.
- Checks that run the engine, each with something that must fail: a program that links
  the library is built and run, and the same program or script without the engine, or
  with a wrong query, or without a certificate it is meant to trust, must not pass.
  A check that cannot fail proves nothing.
- Nothing is fetched at build time and nothing at run time. Where an upstream's build
  wants a git checkout, a network or `/usr/bin/env`, what it does is done in the Nix
  build instead, and the engine's page lists it.
- What is known to work and what is not is written down with the evidence: a platform
  or a nixpkgs that was not built is "not built", which is not "does not work".

### Rust and TLS

Some Rust crates for an engine bring a TLS stack with them. People need one or the
other, so the Rust programs of this repository are built with a choice of `tls`,
`"openssl"` or `"rustls"`, and a feature of a crate that needs TLS when the program runs
uses rustls. How that is done for chDB, and what was checked, is in
[docs/chdb.md](docs/chdb.md#rust).

### Adding an engine

Copy the shape: `pkgs/<engine>` with a `pin.json`, `scripts/update-<engine>.sh`,
`nix/<engine>/{default,overlay,packages,checks}.nix`, an entry in `nix/overlay.nix`,
`nix/lib.nix` and `flake.nix`, and a page in `docs/`. Flakes see only tracked files;
stage new ones. Style is checked by `scripts/lint.sh` (`nix develop`), and CI evaluates
every output for every system without import from derivation.

## Checks and CI

`nix flake check` builds every check, which for DuckDB takes hours (see
[its page](docs/duckdb.md#checks)). GitHub Actions (`.github/workflows/ci.yml`) runs what
does not need a long build: style, evaluation for every system, the pins and sources of
DuckDB, and CMake configuring DuckDB for each version on each nixpkgs.

## License

[Apache-2.0](LICENSE) for the Nix code and scripts in this repository. The engines, their
extensions and the crates are not part of it and keep their own licenses: DuckDB MIT,
chDB, ClickHouse, NeuG and zvec Apache-2.0.
