# DuckDB with extensions, for Nix

This repository builds DuckDB with the extensions that are not in its own tree (`httpfs`, `spatial`, `iceberg`, ...) [linked in](packaging.md#glossary), so the CLI, `libduckdb` and the programs that use it have them with no `INSTALL`, no signature check and no extension directory. nixpkgs' `duckdb` builds only the extensions in DuckDB's own tree; everything else is a signed binary downloaded when the program runs, which does not suit Nix, a sandbox, or a library that is linked rather than run.

| DuckDB | Packages | Extensions linked in |
|---|---|---|
| 2.0.0 (the default) | `duckdb-all`, `duckdb-httpfs`, ... | 28 |
| 1.5.2 | `duckdb-1_5-all`, `duckdb-1_5-httpfs`, ... | 24 |
| 1.4.3 | `duckdb-1_4-all`, `duckdb-1_4-httpfs`, ... | 22, and `duckpgq` to load |

Built and checked on x86_64-linux with glibc, on nixpkgs unstable, 26.05 and 25.11 ([results](#test-results)). The other engines of this repository are in the [README](../README.md).

Contents: [Get it](#get-it) · [Use it](#use-it) · [Things to know](#things-to-know) · [What is in it](#what-is-in-it) · [For maintainers and auditors](#for-maintainers-and-auditors) · [Open items](#open-items) · [License](#license)

## Get it

There is a package for each extension, and `nix flake show` lists them:

```sh
nix run github:levigross/engram#duckdb-spatial
nix shell github:levigross/engram#duckdb-httpfs
nix build github:levigross/engram#duckdb-all    # all 28
nix flake show github:levigross/engram          # every package
```

- **Other nixpkgs.** Unstable has no prefix. 26.05 has `stable-` and 25.11 has `previous-`: `#stable-duckdb-spatial`, `#previous-duckdb-all`.
- **Other DuckDB versions.** The line (major.minor, such as `1.4`) is in the name: `nix shell github:levigross/engram#duckdb-1_4-httpfs`, or `#previous-duckdb-1_4-all`, `#stable-duckdb-1_5-all`. See [DuckDB versions](#duckdb-versions).
- **No extension.** `#duckdb` is DuckDB 2.0.0 with none linked in, as nixpkgs would build it.
- **Platforms.** Only x86_64-linux with glibc has been built. The flake lists aarch64-linux and aarch64-darwin as well; they evaluate and have not been built.
- **First build.** Nothing is cached, so the first build compiles DuckDB: see [Things to know](#things-to-know).

## Use it

### Command line

```sh
nix run github:levigross/engram#duckdb-all -- -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1"
```

This is DuckDB's own shell. Every extension that was linked in is loaded at startup. Two extensions of 2.0 need switching on first: [psql and duckpgq](#things-to-know).

### Python module

```sh
nix build github:levigross/engram#python3-duckdb-all    # DuckDB 2.0.0, every extension linked in
```

```nix
python3.withPackages (ps: [
  ((engram.lib.duckdb pkgs).withExtensions (e: [ e.httpfs ])).pythonModule ps
])
```

- The module has its own copy of DuckDB with the extensions linked in. It does not use `libduckdb`.
- The module alone: `(duckdb.withExtensions (e: [ e.httpfs ])).pythonModule python3Packages`.
- Packages: `python3-duckdb-all` (2.0), `python3-duckdb-1_5-all`, `python3-duckdb-1_4-all`; without extensions, `python3-duckdb`, `python3-duckdb-1_5`, `python3-duckdb-1_4`.
- Not every combination of version and nixpkgs has been built; the rest are untried, not known to fail: [Python module: test results](#python-module-test-results).

### From Rust or C++

`libduckdb` has the extensions linked in, so a program that links it has them without `INSTALL` or `LOAD`. For the `duckdb` crate, point it at this build:

```nix
rustPlatform.buildRustPackage {
  # ...
  env = {
    DUCKDB_LIB_DIR = "${lib.getLib duckdb}/lib";
    DUCKDB_INCLUDE_DIR = "${lib.getDev duckdb}/include";
  };
}
```

with the crate in `Cargo.toml`:

```toml
duckdb = { version = "=1.20000.1", default-features = false }
```

- The crate must be the one for that DuckDB: `=1.20000.1` for 2.0.0, `=1.10502.0` for 1.5.2, `=1.4.3` for 1.4.3.
- A C++ program takes `libduckdb` from `lib.getLib duckdb` and the headers from `lib.getDev duckdb`.
- `examples/rust-consumer` is a Rust program like this, and the `rust-consumer` check builds it for every version.

### In a flake

`lib.duckdb` takes your package set and gives back `duckdb` with `withExtensions`. It changes nothing else in `pkgs`, which makes it the way to start:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    engram.url = "github:levigross/engram";
    engram.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, engram, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      duckdb = engram.lib.duckdb pkgs;
    in
    {
      packages.x86_64-linux.default = duckdb.withExtensions (e: [
        e.httpfs
        e.spatial
      ]);

      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ (duckdb.withExtensions (e: [ e.httpfs ])) ];
      };
    };
}
```

`follows` makes the flake's own packages (`engram.packages.<system>.duckdb-httpfs`) build with your nixpkgs too. That matters when something links `libduckdb`, since a program built with one glibc cannot load a library built with a newer one. With flake-parts it is the same call in `perSystem`:

```nix
perSystem = { pkgs, ... }: {
  packages.default = (inputs.engram.lib.duckdb pkgs).withExtensions (e: [ e.zipfs ]);
};
```

### A different DuckDB version

DuckDB 2.0.0 is the default. The DuckDB that nixpkgs 26.05 and 25.11 ship, 1.5.2 and 1.4.3, can have the extensions too. Ask for the [line](packaging.md#glossary) (`"1.5"`, `"1.4"`) or the release (`"1.5.2"`, `"1.4.3"`; they are the same build):

```nix
let
  duckdbs = engram.lib.duckdbVersions pkgs; # as lib.duckdb is, for every version
  duckdb = duckdbs."1.4";                       # 1.4.3; duckdb.version says which
in
duckdb.withExtensions (e: [ e.httpfs e.spatial ])
```

| Where | How |
|---|---|
| flake | `engram.lib.duckdbVersions pkgs` as above; `lib.duckdb pkgs` is still 2.0.0 |
| overlay | `pkgs.duckdbVersions."1.4"`; `pkgs.duckdb` is still 2.0.0 |
| command line | the line is in the package name, see [Get it](#get-it) |

The Rust crate and the Python module follow the DuckDB you chose: see [From Rust or C++](#from-rust-or-c) and [Python module](#python-module).

`map (e: e.name) duckdb.linkableExtensions` lists what that version can link with your nixpkgs. An extension its release does not have fails with a message that says so, not with an evaluation error. What differs between versions is in [DuckDB versions](#duckdb-versions).

### NixOS and home-manager

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [
    ((engram.lib.duckdb pkgs).withExtensions (e: [ e.httpfs e.spatial ]))
  ];
}
```

The same expression goes in `home.packages` for home-manager.

### As an overlay

```nix
import nixpkgs { inherit system; overlays = [ engram.overlays.default ]; }
# or, in a NixOS configuration: nixpkgs.overlays = [ engram.overlays.default ];
```

then `pkgs.duckdb.withExtensions (e: [ ... ])` as above. This replaces `pkgs.duckdb` for everything that uses it, which has a cost: **a Python package that depends on `duckdb` no longer evaluates.** `python3Packages.duckdb` of nixpkgs and `python3Packages.ibis-framework` both fail with "cannot coerce a function to a string". The module of this flake is `python3-duckdb`. Prefer `lib.duckdb` unless you want the replacement.

The error comes from nixpkgs' Python builder. It takes any dependency that has a `pythonModule` attribute for a Python library, and prints the Python that built it (`toString drv.pythonModule`). The `duckdb` of this flake has an attribute of that name, `pythonModule` in `pkgs/duckdb/default.nix`, which is a function, and a function cannot be printed. (`python3Packages.duckdb` would also fail without that: its hash is for the DuckDB that nixpkgs ships.) It was met while running chDB's tests, which import ibis when it is there.

### Your own extension

```sh
nix flake init -t github:levigross/engram#extension
nix build
./result/bin/duckdb -c "SELECT hello('Nix')"
```

The template is a small extension in C++ (`hello(name)`) and a flake that links it into DuckDB with `engram.lib.duckdb`. `duckdb.mkExtension` takes the source directory, which has a `CMakeLists.txt` as in [DuckDB's extension template](https://github.com/duckdb/extension-template), and the libraries it needs in `buildInputs`. `withExtensions` then links it like the packaged ones: `duckdb.withExtensions (e: [ e.httpfs hello ])`. DuckDB's own test suite runs on the result, as it does for the others.

## Things to know

- **Nothing is cached.** The first build of a selection compiles DuckDB and runs its test suite. For a quick look, `.overrideAttrs { doInstallCheck = false; }` leaves the suite out.
- **Size.** `libduckdb.so` with all 28 extensions of 2.0.0 is 911 MB, mostly lance's DataFusion stack. Link only what you use.
- **aws and threads.** With the aws extension linked in, two threads that each open their first database at the same moment can corrupt the heap. Open one database or connection before starting threads that open more. The Python module of 2.0 has a lock; the CLI, the Rust library and the 1.x Python modules do not. [Evidence](#aws-two-databases-opened-at-the-same-time).
- **psql and duckpgq need switching on in 2.0**, since from DuckDB 2.0 a grammar is per connection. duckpgq: `SET active_grammar_extensions = ['duckpgq']`. psql: `CALL psql_enable()` in the shell, which sets its own grammar; a program that links `libduckdb` has psql on in every connection. Before 2.0 neither has a grammar to switch on: psql adds its pipe syntax to every connection as soon as it is loaded, and duckpgq is only a file to load.
- **duckpgq on 1.4 is loaded, not linked.** See [Graph queries on DuckDB 1.4](#graph-queries-on-duckdb-14-duckpgq).
- **Query.Farm's community extensions are not packaged.** For DuckDB 2.0 the ones of Query.Farm (datasketches, hashfuncs, crypto, ...) are stubs that load a build from Query.Farm's own repository.
- **The overlay breaks Python packages that depend on `duckdb`.** See [As an overlay](#as-an-overlay).

## What is in it

### The extensions

DuckDB 2.0.0 has 29 extensions outside its tree. 28 are linked in; `odbc_scanner` is a C API extension (built against DuckDB's C extension API), which exists only as a file to load, so it cannot be linked and has no package.

| Needs | Extensions |
|---|---|
| no dependencies | encodings, fts, inet, legacy_parser, sqlsmith, sqlite_scanner, vss, duckpgq, psql, sheetreader |
| system libraries | httpfs, quack, excel, aws, glue, azure, ducklake, iceberg, avro, unity_catalog, postgres_scanner, mysql_scanner, spatial, zipfs, webbed |
| Rust | lance, delta, vortex |
| cannot be linked | odbc_scanner |

Asking for an extension that needs another gets it too (`iceberg` brings `avro` and `httpfs`, and `quack` brings `httpfs`).

Each is the commit the DuckDB release pins in `.github/config/extensions/`. The exceptions are community extensions: duckpgq (SQL/PGQ graph queries), psql (a pipe syntax), sheetreader (fast XLSX reading), webbed (XML and HTML) and zipfs (files inside zip and other archives). Their commit is the one the `duckdb/community-extensions` descriptor (the `description.yml` of the extension in that registry, which names its source commit) gives for the release, and only if the registry published a build of the extension for it. A descriptor is not proof that the extension is there: see [Things to know](#things-to-know) for Query.Farm's.

### DuckDB versions

2.0.0 is the default, and [another is asked for](#a-different-duckdb-version) by its line or release. A line has one [pinned](packaging.md#glossary) release, the one that the nixpkgs in the table ships, and a project gets the one in the `flake.lock` of its `engram` input.

| DuckDB | Ships in | `duckdb` crate | Python module |
|---|---|---|---|
| 2.0.0 | none of the three | `=1.20000.1` | `python3-duckdb` |
| 1.5.2 | nixpkgs 26.05 | `=1.10502.0` | `python3-duckdb-1_5` |
| 1.4.3 | nixpkgs 25.11 | `=1.4.3` | `python3-duckdb-1_4` |

At this `flake.lock`, nixpkgs unstable ships 1.5.5, 26.05 ships 1.5.2 and 25.11 ships 1.4.3.

The `duckdb` crate that goes with a release is the one in the table. Up to 1.4 it is numbered as the release. For 1.5.2 and 2.0.0 it is numbered `1.<major * 10000 + minor * 100 + patch>.<n>`; `scripts/update-duckdb.sh` finds it.

What a version has is what its release has. `scripts/availability.sh` lists, for every version and nixpkgs, each extension that cannot be had and why. It prints the same for all three nixpkgs:

| DuckDB | Extensions not offered | Why |
|---|---|---|
| 2.0.0 | `odbc_scanner` | a C API extension: it can only be loaded at runtime |
| 1.5.2 | `glue`, `legacy_parser`, `quack` | not in the release; asking for one says so |
| 1.5.2 | `duckpgq` | the registry published no build of it for 1.5.2 |
| 1.5.2 | `odbc_scanner` | a C API extension, as in 2.0.0 |
| 1.4.3 | `glue`, `lance`, `legacy_parser`, `odbc_scanner`, `quack` | not in the release; asking for one says so |
| 1.4.3 | `sheetreader` | the registry published no build of it for 1.4.3 |
| 1.4.3 | `duckpgq` | in the registry, but needs a fork of DuckDB, so it is offered to load, not to link |

A community extension is pinned only if the registry published a build of it for the release, at the descriptor the registry had while it built that release.

### Graph queries on DuckDB 1.4 (duckpgq)

duckpgq adds property graphs and `GRAPH_TABLE … MATCH` queries (SQL/PGQ). On 1.4.3 it is not linked in, because its sources need the parser of `cwida/duckdb-pgq`, a fork of DuckDB. You load it into the DuckDB 1.4 of this flake instead. `duckdb-1_4-all` has the other 22 extensions linked in; `duckdb-1_4` has none. It comes in two builds, and each is a package:

| Package | What it is | To load it |
|---|---|---|
| `duckdb-1_4-duckpgq-registry-loadable` | the registry's own build for 1.4.3, signed, pinned by its hash (not built here) | `duckdb` |
| `duckdb-1_4-duckpgq-loadable` | built here from the sources, against the fork of DuckDB they need | `duckdb -unsigned` |

DuckDB loads an unsigned extension only when it is told to, with `duckdb -unsigned` or `allow_unsigned_extensions` when the database is opened (without it, it says so and refuses). For 26.05 and 25.11 the packages have the `stable-` and `previous-` prefixes. On the 2.0 line duckpgq is linked in (`duckdb-duckpgq`) and needs no `LOAD`, only the `SET` in [Things to know](#things-to-know).

**From the command line**, build the extension, start DuckDB 1.4 and load it:

```sh
ext=$(nix build --no-link --print-out-paths github:levigross/engram#duckdb-1_4-duckpgq-registry-loadable)
echo "$ext"
nix run github:levigross/engram#duckdb-1_4-all        # add -- -unsigned for the one built here
```

```sql
LOAD '/nix/store/…-duckdb-duckpgq-registry-1.4.3/lib/duckpgq.duckdb_extension';  -- the path echoed above

CREATE TABLE person AS SELECT * FROM (VALUES (1, 'Ann'), (2, 'Bob'), (3, 'Cy')) t(id, name);
CREATE TABLE knows AS SELECT * FROM (VALUES (1, 2), (2, 3)) t(a, b);
CREATE PROPERTY GRAPH g
  VERTEX TABLES (person)
  EDGE TABLES (knows SOURCE KEY (a) REFERENCES person (id)
                     DESTINATION KEY (b) REFERENCES person (id) LABEL knows);

-- who knows whom
FROM GRAPH_TABLE (g MATCH (x:person)-[k:knows]->(y:person)
                  COLUMNS (x.name AS from_name, y.name AS to_name));

-- the shortest paths out of Ann, up to three hops
FROM GRAPH_TABLE (g MATCH p = ANY SHORTEST (x:person)-[k:knows]->{1,3}(y:person)
                  WHERE x.id = 1
                  COLUMNS (x.name AS from_name, y.name AS to_name, path_length(p) AS hops));
```

duckpgq reads the tables while it parses the statement that creates a graph, so the tables must exist by then: run the statements one after another, as a script piped into the shell does, and not all in one `-c` string (the check runs them as separate commands for that reason). The last query returns Ann→Bob in 1 hop and Ann→Cy in 2.

**By name**, with `LOAD duckpgq`, the extension directory of the package is set first:

```sql
SET extension_directory = '/nix/store/…-duckdb-duckpgq-registry-1.4.3/share/duckdb/extensions';
LOAD duckpgq;
```

**From Nix**, the packages are in `loadableExtensions` of the DuckDB of the line, so a script or a wrapper can name the file without a store path:

```nix
let
  duckdb = (engram.lib.duckdbVersions pkgs)."1.4";
  duckpgq = duckdb.loadableExtensions.duckpgq-registry;   # or .duckpgq, built here
in
"${duckpgq}/${duckpgq.path}"    # …/lib/duckpgq.duckdb_extension
```

What was run to check this is under [Checks](#checks) (`loadable-extensions-1_4`) and in [what was run](#duckpgq-on-14-what-was-run).

### nixpkgs versions

The flake pins `nixos-unstable`, `nixos-26.05` and `nixos-25.11`. Every package and check exists for each, the older two behind a `stable-` and a `previous-` prefix, and the overlay works on whichever nixpkgs you apply it to.

Every extension of a version is linked on every nixpkgs, so `duckdb-all` has the same extensions on all three; a package for an extension that a nixpkgs could not build would not be offered there,, and `scripts/availability.sh` finds none. Where a nixpkgs lacks what an extension needs, the extension adapts (spatial to the GDAL it has) or brings its own (azure on 25.11): see [what differs by version and nixpkgs](#what-differs-by-version-and-nixpkgs). CI configures each of the three versions on each of the three; [what was built and checked](#test-results) is below.

## For maintainers and auditors

You do not need this part to use the flake. It says how the packages are made, what is checked, what is left out and why, and what the checks showed.

### How it is built

#### Pins and the update script

`scripts/update-duckdb.sh [tag]` computes every [pin](packaging.md#glossary) from an upstream release into `pkgs/duckdb/versions/<version>/`, one directory for each DuckDB version: DuckDB's commit and hash, each extension's commit and hash, the submodules they need, the Rust lock files and the hashes of their git dependencies. Nothing is copied from another repository. Besides `version.json` and `pins.json`, a directory can hold:

- `python.json`: duckdb-python at the same tag, for the Python module.
- `rust-consumer.json`: before 2.0, the `duckdb` crate that goes with the release, with the lock file of the example program.
- `unavailable.json`: the community extensions the registry published no build of for that release.
- `loadable.json`: a community extension that cannot be linked in, with its sources and the registry's own build for each system.

#### Sources and linking

- Each extension's source is its own small derivation (`source-<name>`, and `source-1_4-<name>` for another version): the pin, its submodules, DuckDB's own patches for it and ours. A patch that stops applying fails in seconds, not after a DuckDB build.
- `pkgs/duckdb` overrides nixpkgs' `duckdb` and links the selection. The link order is the load order, so the in-tree extensions come first and dependencies before their users.
- The build without extensions keeps the same derivation as nixpkgs' would, so it is not rebuilt when this machinery changes.

#### The Rust extensions

lance, delta and vortex build their Rust half by running cargo from CMake, which needs the network. Here it is a separate derivation (`rust-<name>`) built by nixpkgs' `rustPlatform` from a `Cargo.lock` kept in the repository. Evaluating the flake never builds or fetches anything, so it works with `allow-import-from-derivation = false`, as Hydra (nixpkgs' build farm) requires.

- They use the official 1.99.1 toolchain from `rust-overlay`. nixpkgs' `rustc` is linked against LLVM 21 while its standard library declares AVX-512 intrinsics for LLVM 22, and `lance-linalg` does not compile with it.
- Several Rust static libraries cannot be linked together, since each carries its own `std`. The symbols more than one defines are renamed per library (`pkgs/duckdb/isolate-rust.nix`), which gives each a private `std` as a loadable extension would have.
- vortex needed more: the `Cargo.lock` upstream commits disagrees with its own `Cargo.toml` (the update script re-resolves it), and crates that take the workspace's README as their documentation find none in the vendor directory. The build script also regenerates a header with a tool that needs the monorepo layout, so the build uses the committed header. Upstream regenerates it on every build; the smoke test is there to catch it lagging.

#### What differs by version and nixpkgs

- **spatial** adapts its sources to the GDAL of the nixpkgs: GDAL changed the interface of its file system in 3.12 and 3.13, and the sources of 1.4 and 1.5 are written for 3.11, those of 2.0 for 3.12. unstable has 3.13, 26.05 has 3.12 and 25.11 has 3.11, and every version builds on every one of them.
- **azure** needs the Azure SDK for C++, which nixpkgs 25.11 does not have; five of its packages are copied from 26.05 (`pkgs/duckdb/azure-sdk-for-cpp`) for it.
- **vortex** before 2.0 is a crate of the vortex repository, which the extension has as a submodule, not a crate of its own.
- **mysql_scanner** of 1.4 links the client library of MySQL 8.4, which is the API its sources use; MariaDB's is not the same.
- **avro and mysql_scanner** link nixpkgs' libraries instead of the ones vcpkg (the C++ package manager DuckDB's extension builds use) builds for the release, and **delta** builds delta-kernel-rs at the release the extension names, with the lock file that this repository generates (the kernel does not commit one before 0.21).
- **The Python module of 2.0** needs `nanobind` 3, which comes from `pkgs/duckdb/nanobind.nix` on 26.05 and 25.11.

#### The Python module

`pkgs/duckdb/python.nix` builds the module with the extensions of its DuckDB linked in. It has its own copy of DuckDB, given the same sources, extensions and flags. What it changes for each line:

- **1.5**: its CMake links only the extensions that `BUILD_EXTENSIONS` names, and those of this flake come in through `DUCKDB_EXTENSION_CONFIGS`, so the loop that links them is given their names. The 1.x modules are built without jemalloc, which DuckDB's CMake adds on Linux.
- **1.4**: `mysql_scanner` links the shared `libmysqlclient.so`, not the static library the CLI links. The static one makes `import duckdb` fail: see [the evidence](#evidence-import-duckdb-fails-in-the-14-module).
- **2.0**: the tests are run with [the exclusions](#tests-left-out-of-the-20-python-module), and tests that start `python -I` get a `sys.executable` that finds the module (nixpkgs' interpreter takes `NIX_PYTHONPATH` out of the environment as it starts). With aws linked in, a mutex serialises the loads of the extension: see [the aws race](#aws-two-databases-opened-at-the-same-time).

### Checks

A [check](packaging.md#glossary) is a build that fails if something is wrong; each one also has something that must fail (a [negative control](packaging.md#glossary)), so it cannot pass by accident.

| Check | What it proves |
|---|---|
| `extension-pins` | each extension is the commit its source names, and every extension DuckDB configures is packaged |
| `rust-extension-api` | custom and replacement Rust archives are selected for both native and Python builds; multiple archives are isolated, and changing an input changes the isolation derivation |
| `httpfs` | reads a CSV over HTTP; the same query fails on plain DuckDB |
| `all-extensions` | every extension is loaded without `INSTALL` and passes an offline smoke test |
| `rust-consumer` | a Rust program on the `duckdb` crate finds the extensions; the same binary against plain DuckDB does not |
| `loadable-extensions` | each extension that is only loaded works in the DuckDB of its release, and its SQL fails without it |
| `example-extension` | the extension of `templates/extension` is linked in as a user of the flake would link it |
| `<check>-1_4`, `<check>-1_5` | each check above for the other versions of DuckDB |

What each does, beyond the table:

- **`extension-pins`** compares each pin with the commit that DuckDB's configuration for the release names (its CMake files, run as CMake) or, for a community extension, that its descriptor names (`description.yml`, read as YAML). A pin that is wrong, missing or extra shows up as a diff.
- **`rust-extension-api`** evaluates the flags for custom extensions and a replacement for a bundled extension without compiling DuckDB or Rust. These assertions also run in CI's evaluation job. It checks archive selection and isolation inputs; it does not prove that a custom archive links or runs.
- **`all-extensions`**: a smoke test is a short offline query that needs the extension. Vortex, lance and delta do real round trips; postgres_scanner and mysql_scanner get a failed connection from libpq and MariaDB. Counting what is loaded is the check that matters: CMake carries on without an extension it could not build, and says so in a line that is easy to miss.
- **`loadable-extensions`** exists where a version has extensions that can only be loaded (duckpgq on 1.4). It loads each into the DuckDB of the release, runs its smoke test, expects the SQL to fail without the extension, loads it by name through `extension_directory`, and expects the one built here to be refused without `-unsigned`.
- **Other versions** of DuckDB have the same checks on every nixpkgs: `previous-all-extensions-1_4`, `stable-rust-consumer-1_5`, `loadable-extensions-1_4`.
- **`example-extension`** is built on unstable only, since the mechanism is the same for every nixpkgs.
- **DuckDB's own test suite** runs in `installCheckPhase`, as in nixpkgs. What cannot pass in this build is listed under [Left out on purpose](#left-out-on-purpose).

#### What CI runs

The checks build DuckDB several times, each with its test suite: about two hours with 12 cores for all three nixpkgs. A free hosted GitHub runner has 4 cores and a six-hour limit, so run them yourself with `nix flake check`. GitHub Actions (`.github/workflows/ci.yml`) runs what does not need a DuckDB build:

- style, with `scripts/lint.sh`;
- evaluation for every system, without import from derivation;
- every extension's source, and the `extension-pins` check of every version;
- CMake configuring DuckDB for each version on each nixpkgs.

### Left out on purpose

DuckDB's test suite runs in the build of every selection. Each test that is left out is printed in the build log with its reason (the reasons are in `pkgs/duckdb/tests.nix` and `pkgs/duckdb/extensions/default.nix`). A test that only needs something different, such as an extension loaded, runs in its own invocation instead of being dropped.

| Left out | Where | Why |
|---|---|---|
| `test/sql/logging/http_response_log_redaction.test` | every build | installs an extension over HTTP; needs network access |
| `test/sql/attach/remote_file_concurrently.test` | httpfs, 1.4 and 1.5 | attaches a database over HTTP; needs network access |
| "Test catalog versioning" | vortex of 1.4 | expects catalog version 1 once open; with 1.4's vortex linked in alone it is not |
| `test/extension/local_extension_coverage.test` | sqlite_scanner | asserts `LOAD sqlite` fails because the extension is absent |
| "V2: GEOMETRY with an unknown coordinate system" | spatial | expects EPSG:4326 to be unknown; spatial's coordinate system database knows it |
| 22 C++ cases, named in the build log | `postgres_scanner` | run a `LogicalPlanStatement`, which cannot be copied; pass without postgres_scanner loaded |
| 4 C++ cases on grammars | `psql`, 2.0 | psql switches its grammar on in every connection, so they find one more; pass without psql |

- "Test catalog versioning" passes with the vortex of 1.5 and with every other extension.
- The `LogicalPlanStatement` is copied by the core whenever a client state asks to be able to rebind, as this extension's does. Its only use outside tests is a developer tool.
- The grammar tests fail the same way when run apart with nothing loaded.
- Tests that run apart instead: two of quack's need httpfs loaded (`quack_serve` needs its crypto module), and `test/sql/connect/connect_passthrough_quack.test` runs in its own process, because it fails after `comment_on_column_remote_catalog.test` in one process when any of lance, mysql_scanner, postgres_scanner, spatial, unity_catalog or vortex is linked.

#### Tests left out of the 2.0 Python module

The 1.x modules leave out only what nixpkgs does. The 2.0.0 module leaves out the following, each by id in `pkgs/duckdb/python.nix` with its reason. The first group fails the same on a module with no extension linked in (found by building one), so it does not come from the extensions. Several of these are not looked into: they are out because they fail without our extensions, not because they are known to be wrong tests.

| Left out | Why |
|---|---|
| four tests with polars | fail with nixpkgs' polars too; not looked into |
| one test writing a `list_view` column to Parquet | pyarrow cannot write one |
| a time zone test | `utcoffset returned an invalid timedelta` |
| `test_8522`, `test_fetch_arrow_reader` | fail without extensions; not looked into |
| two interrupt tests | hang when their file runs; each passes alone |
| three groups | crash the interpreter: scanning Arrow `string_view` with pyarrow 24, and a shutdown with daemon threads that scan |

The second group fails only with the extensions, because the test expects a bare DuckDB:

| Left out | Why |
|---|---|
| two aws tests | aws registers two default secrets, and its SDK keeps threads after a database is closed |
| one test of threads at import | with spatial, mysql_scanner, postgres_scanner or sqlite_scanner linked in, a jemalloc background thread exists once the module is imported |

`tests/fast/expression/test_expression_generated.py` is left out as well. It reads the `duckdb/` directory of the sources, which the check removes so that it cannot shadow the module.

### Test results

#### DuckDB builds

What has been built with DuckDB's own test suite and then the pins, all-extensions, Rust consumer (and for 1.4, loadable-extensions) checks, on x86_64-linux:

| DuckDB | unstable | 26.05 | 25.11 |
|---|---|---|---|
| 2.0.0 | passes | passes | passes (the suite failed once, see below) |
| 1.5.2 | passes | passes | passes |
| 1.4.3 | passes | passes | passes |

2.0.0 on 25.11 failed one of 7800 test cases once, `test/api/test_query_result_format_buffer.cpp:108` (`REQUIRE(report.saw_blocked_sink)`): a producer thread of the result stream was meant to park and did not. It is a test of thread timing in DuckDB's own core, which involves no extension. The same derivation, built again on the same machine, passed the whole suite (7769 test cases run, 31 skipped) and all four checks, so the test is nondeterministic. Why it failed was not isolated. The test is not left out: a failure of it alone is worth a second run.

#### Python module: test results

A module, with every extension its DuckDB can link, is checked in its build: it imports, every extension it was given shows as loaded in `duckdb_extensions()`, and the test suite of duckdb-python runs with pytest, as nixpkgs runs it. x86_64-linux:

| DuckDB | unstable | 26.05 | 25.11 |
|---|---|---|---|
| 2.0.0 | passes: 28 extensions, 16329 passed, 129 skipped, 54 deselected, 227 xfailed, 1 xpassed | not built | not built |
| 1.5.2 | not built | passes: 24 extensions, 3261 passed, 35 skipped, 11 deselected, 9 xfailed | not built |
| 1.4.3 | not built | passes: 22 extensions, 3289 passed, 34 skipped, 11 deselected, 3 xfailed | not built |

- "Not built" means nothing was run, not that it fails. They are the same packages on another nixpkgs.
- The 2.0.0 module on 26.05 and 25.11 also depends on `nanobind` 3, which comes from `pkgs/duckdb/nanobind.nix` there and is untried.
- pytest terms: *deselected* tests are left out by this build, by id; *xfailed* tests are marked by upstream as expected to fail, and did; an *xpassed* test was expected to fail and passed.

#### Evidence: import duckdb fails in the 1.4 module

`import duckdb` failed with `cannot allocate memory in static TLS block`, on 25.11 and on 26.05 (so it is not the glibc of 25.11). The static TLS block is the small fixed reserve of thread-local storage that glibc keeps for libraries loaded after the program starts, as Python loads this module.

- The cause is `mysql_scanner`, which linked `libmysqlclient.a`, built for programs: it keeps `my_errno` in thread-local storage of the initial-exec kind, which puts the whole thread-local block of the module (about 10 KB) into that reserve.
- The module without `mysql_scanner` imported, and so did the full one with a larger reserve (`GLIBC_TUNABLES=glibc.rtld.optional_static_tls=16384`; 4096 was not enough).
- The shared `libmysqlclient.so` has 4 bytes of it, and linking that fixes the module. It is not jemalloc. The CLI is unaffected, so it still links the static library.

#### duckpgq on 1.4: what was run

The session in [Graph queries](#graph-queries-on-duckdb-14-duckpgq) runs as written with the extension built here (`duckdb -unsigned`), and DuckDB refuses it without `-unsigned`. The `loadable-extensions-1_4` check (and `previous-` and `stable-`) loads both builds into DuckDB 1.4.3 in the sandbox, runs graph queries and expects them to fail without the extension. The command lines above were not run against the registry's build outside that check, and the extension has not been loaded from the Python module of 1.4.

#### aws: two databases opened at the same time

When the aws extension is linked in, two threads that each open their first database at the same moment can corrupt the heap (a double free). The extension initialises the AWS SDK and sets its process-wide HTTP client factory every time a database loads it, with nothing that keeps two loads apart. Seen through Python: `test_two_threads_open_the_default_connection` failed in 14 of 60 runs, each in its own process, of a module with only aws linked in, in none of 60 with no extension, and in none of 60 with the loads serialized.

The Python module of 2.0 has that lock (`pkgs/duckdb/python.nix`, a mutex around the load). The CLI and the Rust library load the same code and do not; the race was only observed through Python, and the aws extension of 1.5.2 and 1.4.3 was not read. The patch is applied for 2.0 only, so the 1.x Python modules have no lock either. Until the extension itself is patched, open one database or connection before starting threads that open more.

### Developing

- `dev-keep-going` builds everything without the test suite; `dev-check` and `dev-rust-check` run the checks against it; `dev-configure` stops after CMake. For another version the line is in the name (`dev-configure-1_5`).
- For tests, build `unittest` once in a directory you keep (`nix develop .#duckdb-all`, then unpack, patch, configure and `ninja test/unittest`), and rerun single tests or relink with a subset of the extensions in a minute. That is how the test failures were attributed to individual extensions. `nix develop .#<name>` opens the build environment of any package, not only of a `devShells` entry; `.#dev-test-shell` is the small set (quack and sqlite_scanner) that reproduces the extension-related failures.
- `nix develop` with no name opens the shell with the tools CI runs, for `scripts/lint.sh`.
- Flakes see only tracked files; stage new ones.

## Open items

See [TODO](TODO.md#duckdb).

## License

[Apache-2.0](../LICENSE) for the Nix code and scripts in this repository. DuckDB, the extensions and the Rust crates it builds are not part of it and keep their own licenses.
