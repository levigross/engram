# DuckDB with extensions, for Nix

This is the part of the repository about DuckDB. The other engines, and what the repository
does for all of them, are in the [README](../README.md).

DuckDB's extensions linked into DuckDB itself, so the CLI, `libduckdb` and its
users get them with no `INSTALL`, no signature check and no extension directory.

nixpkgs' `duckdb` builds only the extensions in DuckDB's own tree. Everything else
(`httpfs`, `spatial`, `iceberg`, ...) has to be downloaded at runtime as a signed
binary, which does not suit Nix, a sandbox, or a library that is linked rather than run.

Status: DuckDB 2.0.0, x86_64-linux with glibc. 28 of the 29 out-of-tree extensions
link and pass their checks on nixpkgs unstable, and most of them on the two latest
stable releases (see [nixpkgs versions](#nixpkgs-versions)). The DuckDB that each of
those ships, 1.5.2 and 1.4.3, is available too, with the extensions its release has
(see [DuckDB versions](#duckdb-versions)). See also [Not done](#not-done).

## Using it

### Try it

There is a package for each extension, and `nix flake show` lists them:

```sh
nix run github:levigross/engram#duckdb-spatial
nix shell github:levigross/engram#duckdb-httpfs
nix build github:levigross/engram#duckdb-all    # all 28
```

For 26.05 and 25.11 the names carry a prefix: `#stable-duckdb-spatial`,
`#previous-duckdb-all`. An extension that a nixpkgs cannot build has no package there.
`#duckdb` is DuckDB 2.0.0 with none, as nixpkgs would build it.

The other DuckDB versions have the line in the name: `#duckdb-1_4-httpfs`,
`#previous-duckdb-1_4-all`, `#stable-duckdb-1_5-all` (see
[DuckDB versions](#duckdb-versions)).

### In your flake

`lib.duckdb` takes your package set and gives back `duckdb` with `withExtensions`. It
changes nothing else in `pkgs`, which makes it the way to start:

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

`follows` makes the flake's own packages (`engram.packages.<system>.duckdb-httpfs`)
build with your nixpkgs too. That matters when something links `libduckdb`, since a
program built with one glibc cannot load a library built with a newer one. With
flake-parts it is the same call in `perSystem`:

```nix
perSystem = { pkgs, ... }: {
  packages.default = (inputs.engram.lib.duckdb pkgs).withExtensions (e: [ e.zipfs ]);
};
```

### A different DuckDB version

DuckDB 2.0.0 is the default. The DuckDB that nixpkgs 26.05 and 25.11 ship, 1.5.2 and
1.4.3, can have the extensions too. Ask for the line (`"1.5"`, `"1.4"`) or the release
(`"1.5.2"`, `"1.4.3"`; they are the same build):

```nix
let
  duckdbs = engram.lib.duckdbVersions pkgs; # as lib.duckdb is, for every version
  duckdb = duckdbs."1.4";                       # 1.4.3; duckdb.version says which
in
duckdb.withExtensions (e: [ e.httpfs e.spatial ])
```

| | |
|---|---|
| flake | `engram.lib.duckdbVersions pkgs` as above; `lib.duckdb pkgs` is still 2.0.0 |
| overlay | `pkgs.duckdbVersions."1.4"`; `pkgs.duckdb` is still 2.0.0 |
| command line | `nix shell github:levigross/engram#duckdb-1_4-httpfs`, or `#previous-duckdb-1_4-all` to build it with nixpkgs 25.11 (`#stable-duckdb-1_5-all` for 1.5 with 26.05) |
| Rust or C++ | `lib.getLib duckdb` and `lib.getDev duckdb` of the one you chose, as in [From Rust or C++](#from-rust-or-c); the `duckdb` crate must be the one for that DuckDB |
| Python | `(duckdb.withExtensions (e: [ e.httpfs ])).pythonModule python3Packages`, or the package `python3-duckdb-all` (2.0): the module with the extensions linked in; `python3-duckdb-1_5-all` and `python3-duckdb-1_4-all` for the other lines. [Which of them have been built](#python-module) |

`map (e: e.name) duckdb.linkableExtensions` lists what that version can link with your
nixpkgs. An extension its release does not have fails with a message that says so, not
with an evaluation error. What differs from 2.0, and what has been built and tested, is
in [DuckDB versions](#duckdb-versions).

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

then `pkgs.duckdb.withExtensions (e: [ ... ])` as above. This replaces `pkgs.duckdb` for
everything that uses it, which has a cost: `python3Packages.duckdb` of nixpkgs no longer
evaluates, since its hash is for the DuckDB that nixpkgs ships; the module of this flake
is `python3-duckdb`. So does what depends on it: evaluating `python3Packages.ibis-framework`
fails with "cannot coerce a function to a string", from the `pythonModule` of
`pkgs/duckdb/default.nix` (met while running chDB's tests, which import ibis when it is
there). Prefer `lib.duckdb` unless you want that replacement.

### From Rust or C++

`libduckdb` has the extensions linked in, so a program that links it has them without
`INSTALL` or `LOAD`. For the `duckdb` crate, point it at this build:

```nix
rustPlatform.buildRustPackage {
  # ...
  env = {
    DUCKDB_LIB_DIR = "${lib.getLib duckdb}/lib";
    DUCKDB_INCLUDE_DIR = "${lib.getDev duckdb}/include";
  };
}
```

with `duckdb = { version = "=1.20000.1", default-features = false }` in `Cargo.toml`
(`=1.10502.0` for DuckDB 1.5.2, `=1.4.3` for 1.4.3).
`examples/rust-consumer` is that program, and the `rust-consumer` check builds it for
every version. For
[an extension of your own](#your-own-extension) the same `withExtensions` takes it.

Nothing is cached yet, so the first build of a selection compiles DuckDB and runs its
test suite. For a quick look, `.overrideAttrs { doInstallCheck = false; }` leaves the
suite out.

## nixpkgs versions

The flake pins `nixos-unstable`, `nixos-26.05` and `nixos-25.11`. Every package and
check exists for each, the older two behind a `stable-` and a `previous-` prefix, and
the overlay works on whichever nixpkgs you apply it to.

Every extension of a version is linked on every nixpkgs, so `duckdb-all` has the same
extensions on all three. Where a nixpkgs lacks what an extension needs, the extension
adapts (spatial to the GDAL it has) or brings its own (azure on 25.11). CI configures
each of the three versions on each of the three; [what was built and checked](#status)
is below.

## DuckDB versions

2.0.0 is the default, and [another is asked for](#a-different-duckdb-version) by its
line or release. A line has one pinned release, the one nixpkgs ships, and a project
gets the one in the `flake.lock` of its `engram` input.

| DuckDB | ships in | linked extensions | `duckdb` crate | Python module |
|---|---|---|---|---|
| 2.0.0 | | 28 | `=1.20000.1` | `python3-duckdb` |
| 1.5.2 | nixpkgs 26.05 | 24 | `=1.10502.0` | `python3-duckdb-1_5` |
| 1.4.3 | nixpkgs 25.11 | 22, and duckpgq to load | `=1.4.3` | `python3-duckdb-1_4` |

What a version has is what its release has. `scripts/availability.sh` lists, for every
version and nixpkgs, each extension that cannot be had and why; it prints this:

- **Not in the release:** 1.4.3 has no `glue`, `lance`, `legacy_parser`, `odbc_scanner`
  or `quack`; 1.5.2 has no `glue`, `legacy_parser` or `quack`. Asking for one says so.
- **Not published:** a community extension is pinned only if the registry published a
  build of it for the release, at the descriptor the registry had while it built that
  release. `sheetreader` has none for 1.4.3 and `duckpgq` has none for 1.5.2.
- **duckpgq on 1.4.3** is in the registry, but its sources need the parser of
  `cwida/duckdb-pgq`, a fork of DuckDB, so it cannot be linked into DuckDB. It is
  offered as a file to load instead: see
  [Graph queries on DuckDB 1.4](#graph-queries-on-duckdb-14-duckpgq).
- **odbc_scanner** is a C API extension, which can only be loaded at runtime.

What differs in how they are built:

- **spatial** adapts its sources to the GDAL of the nixpkgs: GDAL changed the interface
  of its file system in 3.12 and 3.13, and the sources of 1.4 and 1.5 are written for
  3.11, those of 2.0 for 3.12. unstable has 3.13, 26.05 has 3.12 and 25.11 has 3.11, and
  every version builds on every one of them.
- **azure** needs the Azure SDK for C++, which nixpkgs 25.11 does not have; five of its
  packages are copied from 26.05 (`pkgs/duckdb/azure-sdk-for-cpp`) for it.
- **vortex** before 2.0 is a crate of the vortex repository, which the extension has as
  a submodule, not a crate of its own.
- **mysql_scanner** of 1.4 links the client library of MySQL 8.4, which is the API its
  sources use; MariaDB's is not the same.
- **avro and mysql_scanner** link nixpkgs' libraries instead of the ones vcpkg builds for
  the release, and **delta** builds delta-kernel-rs at the release the extension names,
  with the lock file that this repository generates (the kernel does not commit one
  before 0.21).

The tests left out are listed in the build log with their reasons; one is the test that
attaches a database over HTTP, in 1.4 and 1.5, and another is "Test catalog versioning"
where the vortex of 1.4 is linked in.

### Graph queries on DuckDB 1.4 (duckpgq)

duckpgq adds property graphs and `GRAPH_TABLE … MATCH` queries (SQL/PGQ). On 1.4.3 it is
not linked in: you load it into the DuckDB 1.4 of this flake, which has everything else.
It comes in two builds, and each is a package:

| package | what it is | to load it |
|---|---|---|
| `duckdb-1_4-duckpgq-registry-loadable` | the registry's own build for 1.4.3, signed, pinned by its hash (not built here) | `duckdb` |
| `duckdb-1_4-duckpgq-loadable` | built here from the sources, against the fork of DuckDB they need | `duckdb -unsigned` |

DuckDB loads an unsigned extension only when it is told to, with `duckdb -unsigned` or
`allow_unsigned_extensions` when the database is opened (without it, it says so and
refuses). For 26.05 and 25.11 the packages have the `stable-` and `previous-` prefixes.

**From the command line**, build the extension, start DuckDB 1.4 and load it:

```sh
ext=$(nix build --no-link --print-out-paths github:levigross/engram#duckdb-1_4-duckpgq-registry-loadable)
echo "$ext"
nix run github:levigross/engram#duckdb-1_4        # add -unsigned for the one built here
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

duckpgq reads the tables while it parses the statement that creates a graph, so the
tables must exist by then: run the statements one after another, as a script piped into
the shell does, and not all in one `-c` string (the check runs them as separate commands
for that reason). The last query returns Ann→Bob in 1 hop and Ann→Cy in 2.

**By name**, with `LOAD duckpgq`, the extension directory of the package is set first:

```sql
SET extension_directory = '/nix/store/…-duckdb-duckpgq-registry-1.4.3/share/duckdb/extensions';
LOAD duckpgq;
```

**From Nix**, the packages are in `loadableExtensions` of the DuckDB of the line, so a
script or a wrapper can name the file without a store path:

```nix
let
  duckdb = (engram.lib.duckdbVersions pkgs)."1.4";
  duckpgq = duckdb.loadableExtensions.duckpgq-registry;   # or .duckpgq, built here
in
"${duckpgq}/${duckpgq.path}"    # …/lib/duckpgq.duckdb_extension
```

How this was checked: the session above runs as written with the extension built here
(`duckdb -unsigned`), and DuckDB refuses it without `-unsigned`. The
`loadable-extensions-1_4` check (and `previous-` and `stable-`) loads both builds into
DuckDB 1.4.3 in the sandbox, runs graph queries and expects them to fail without the
extension. The command lines above were not run against the registry's build outside that
check, and the extension has not been loaded from the Python module of 1.4.

duckpgq of the 2.0 line is another matter: it is linked in (`duckdb-duckpgq`), needs no
`LOAD`, and is switched on with `SET active_grammar_extensions = ['duckpgq']`. 1.5.2 has
no duckpgq, because the registry published none for it.

### Status

What has been built with DuckDB's own test suite and then the pins, all-extensions,
Rust consumer (and for 1.4, loadable-extensions) checks, on x86_64-linux:

| | unstable | 26.05 | 25.11 |
|---|---|---|---|
| 2.0.0 | passes | passes | passes (the suite failed once, see below) |
| 1.5.2 | passes | passes | passes |
| 1.4.3 | passes | passes | passes |

2.0.0 on 25.11 failed one of 7800 test cases once, `test/api/test_query_result_format_buffer.cpp:108`
(`REQUIRE(report.saw_blocked_sink)`): a producer thread of the result stream was meant to
park and did not. It is a test of thread timing in DuckDB's own core, which involves no
extension. The same derivation, built again on the same machine, passed the whole suite
(7769 test cases run, 31 skipped) and all four checks, so the test is nondeterministic.
Why was not isolated, and the test is not left out: a failure of it alone is worth a
second run.

#### Python module

A module, with every extension its DuckDB can link, is checked in its build: it imports,
every extension it was given shows as loaded in `duckdb_extensions()`, and the test suite
of duckdb-python runs with pytest, as nixpkgs runs it. x86_64-linux:

| | unstable | 26.05 | 25.11 |
|---|---|---|---|
| 2.0.0 | passes: 28 extensions, 16329 passed, 129 skipped, 54 deselected, 227 xfailed, 1 xpassed | not built | not built |
| 1.5.2 | not built | passes: 24 extensions, 3261 passed, 35 skipped, 11 deselected, 9 xfailed | not built |
| 1.4.3 | not built | passes: 22 extensions, 3289 passed, 34 skipped, 11 deselected, 3 xfailed | not built |

"Not built" means nothing was run, not that it fails. They are the same packages on another
nixpkgs. The 2.0.0 module on 26.05 and 25.11 also depends on `nanobind` 3, which comes from
`pkgs/duckdb/nanobind.nix` there and is untried.

What was needed to get here, and is in `pkgs/duckdb/python.nix`:

- **1.5**: its CMake links only the extensions that `BUILD_EXTENSIONS` names, and those
  of this flake come in through `DUCKDB_EXTENSION_CONFIGS`, so the loop that links them
  is given their names. The 1.x modules are built without jemalloc, which DuckDB's CMake
  adds on Linux.
- **1.4**: `import duckdb` failed with `cannot allocate memory in static TLS block`, on 25.11
  and on 26.05 (so it is not the glibc of 25.11). The cause is `mysql_scanner`, which linked
  `libmysqlclient.a`, built for programs: it keeps `my_errno` in thread-local storage of the
  initial-exec kind, which puts the whole thread-local block of the module (about 10 KB)
  into the small static reserve glibc keeps for modules loaded later. The module without
  `mysql_scanner` imported, and so did the full one with a larger reserve
  (`GLIBC_TUNABLES=glibc.rtld.optional_static_tls=16384`; 4096 was not enough). The shared
  `libmysqlclient.so` has 4 bytes of it, and linking that fixes the module. It is not
  jemalloc. The CLI is unaffected, so it still links the static library.
- **2.0**: the tests are run with the exclusions below, and tests that start `python -I`
  get a `sys.executable` that finds the module (nixpkgs' interpreter takes
  `NIX_PYTHONPATH` out of the environment as it starts).

Tests left out of the 2.0.0 module (the 1.x modules leave out only what nixpkgs does),
each by id in `pkgs/duckdb/python.nix` with its reason:

- **Failing the same on a module with no extension linked in** (found by building one):
  four tests with polars, one writing a `list_view` column to Parquet that pyarrow cannot
  write, a time zone test (`utcoffset returned an invalid timedelta`), and two more whose cause was not looked into
  (`test_8522`, `test_fetch_arrow_reader`), two interrupt tests that hang when their file
  runs and pass alone, and three groups that crash the interpreter (scanning Arrow
  `string_view` with pyarrow 24, and the shutdown with daemon threads that scan). Several
  of these are not looked into: they are out because they fail without our extensions,
  not because they are known to be wrong tests.
- **Failing only with the extensions, because the test expects a bare DuckDB**: the aws
  extension registers two default secrets and its SDK keeps threads after a database is
  closed (two tests); with spatial, mysql_scanner, postgres_scanner or sqlite_scanner
  linked in, a jemalloc background thread exists once the module is imported (one test).
- The file `tests/fast/expression/test_expression_generated.py` reads the `duckdb/`
  directory of the sources, which the check removes so that it cannot shadow the module.

#### aws: two databases opened at the same time

When the aws extension is linked in, two threads that each open their first database at
the same moment can corrupt the heap (a double free). The extension initialises the AWS
SDK and sets its process-wide HTTP client factory every time a database loads it, with
nothing that keeps two loads apart. Seen through Python: `test_two_threads_open_the_default_connection`
failed in 14 of 60 runs, each in its own process, of a module with only aws linked in,
in none of 60 with no extension, and in none of 60 with the loads serialized.

The Python module of 2.0 has that lock (`pkgs/duckdb/python.nix`, a mutex around the load).
The CLI and the Rust library load the same code and do not; the race was only observed
through Python, and the aws extension of 1.5.2 and 1.4.3 was not read. Until the extension
itself is patched, open one database or connection before starting threads that open more.

The `duckdb` crate that goes with a release is the one named in the table. For 1.5.2 and
2.0.0 it is numbered `1.<major * 10000 + minor * 100 + patch>.<n>`; `scripts/update-duckdb.sh` finds it.

## The extensions

| | |
|---|---|
| no dependencies | encodings, fts, inet, legacy_parser, sqlsmith, sqlite_scanner, vss, duckpgq, psql, sheetreader |
| system libraries | httpfs, quack, excel, aws, glue, azure, ducklake, iceberg, avro, unity_catalog, postgres_scanner, mysql_scanner, spatial, zipfs, webbed |
| Rust | lance, delta, vortex |
| cannot be linked | odbc_scanner (a C API extension, loadable at runtime only) |

Each is the commit the DuckDB release pins in `.github/config/extensions/`. The
exceptions are community extensions: duckpgq (SQL/PGQ graph queries), psql (a pipe
syntax), sheetreader (fast XLSX reading), webbed (XML and HTML) and zipfs (files inside
zip and other archives). Their commit is the one the `duckdb/community-extensions`
descriptor names for the release, and only if the registry published a build of the
extension for it. A descriptor is not proof that the extension is there, though:
for DuckDB 2.0 the Query.Farm ones (datasketches, hashfuncs, crypto, ...) are stubs that
load a build from Query.Farm's own repository, so none of them is packaged.

Some of these need switching on, since from DuckDB 2.0 a grammar is per connection:
duckpgq with `SET active_grammar_extensions = ['duckpgq']`, and psql with
`CALL psql_enable()` in the shell, which sets its own grammar. A program that links
`libduckdb` has psql on in every connection. Before 2.0 neither has a grammar to switch on:
psql adds its pipe syntax to every connection as soon as it is loaded, and duckpgq is only
a file to load (see [DuckDB versions](#duckdb-versions)).

Asking for an extension that needs another gets it too (`iceberg` brings `avro` and `httpfs`).

## How it works

- `scripts/update-duckdb.sh [tag]` computes every pin from an upstream release into `pkgs/duckdb/versions/<version>/`, one directory for each DuckDB version: DuckDB's
  commit and hash, each extension's commit and hash, the submodules they need, the
  Rust lock files and the hashes of their git dependencies. Nothing is copied from
  another repository.
- Each extension's source is its own small derivation (`source-<name>`): the pin,
  its submodules, DuckDB's own patches for it and ours. A patch that stops applying
  fails in seconds, not after a DuckDB build.
- `pkgs/duckdb` overrides nixpkgs' `duckdb` and links the selection. The link order
  is the load order, so the in-tree extensions come first and dependencies before
  their users.
- The build without extensions keeps the same derivation as nixpkgs' would, so it
  is not rebuilt when this machinery changes.

### The Rust extensions

lance, delta and vortex build their Rust half by running cargo from CMake, which
needs the network. Here it is a separate derivation (`rust-<name>`) built by
nixpkgs' `rustPlatform` from a `Cargo.lock` kept in the repository. Evaluating the
flake never builds or fetches anything, so it works with
`allow-import-from-derivation = false`, as Hydra requires.

- They use the official 1.99.1 toolchain from `rust-overlay`. nixpkgs' `rustc` is
  linked against LLVM 21 while its standard library declares AVX-512 intrinsics for
  LLVM 22, and `lance-linalg` does not compile with it.
- Several Rust static libraries cannot be linked together, since each carries its
  own `std`. The symbols more than one defines are renamed per library
  (`pkgs/duckdb/isolate-rust.nix`), which gives each a private `std` as a loadable
  extension would have.
- vortex needed more: the `Cargo.lock` upstream commits disagrees with its own
  `Cargo.toml` (the update script re-resolves it), crates that take the workspace's
  README as their documentation find none in the vendor directory, and the build
  script regenerates a header with a tool that needs the monorepo layout. It uses the committed header,
  which upstream regenerates on every build; the smoke test is there to catch it lagging.

## Your own extension

```sh
nix flake init -t github:levigross/engram#extension
nix build
./result/bin/duckdb -c "SELECT hello('Nix')"
```

The template is a small extension in C++ (`hello(name)`) and a flake that links it into
DuckDB with `engram.lib.duckdb`. `duckdb.mkExtension` takes the source directory,
which has a `CMakeLists.txt` as in [DuckDB's extension template](https://github.com/duckdb/extension-template),
and the libraries it needs in `buildInputs`. `withExtensions` then links it like the
packaged ones: `duckdb.withExtensions (e: [ e.httpfs hello ])`. DuckDB's own test
suite runs on the result, as it does for the others.

## Checks

| | |
|---|---|
| `extension-pins` | every extension is the commit its source names (DuckDB's configuration, run as CMake, or a community descriptor, read as YAML), and every extension DuckDB configures is packaged |
| `httpfs` | reads a CSV over HTTP; the same query fails on plain DuckDB |
| `all-extensions` | every extension is loaded without `INSTALL`, and each passes an offline smoke test (real round trips for vortex, lance and delta; a failed connection from libpq and MariaDB) |
| `rust-consumer` | a Rust program using the `duckdb` crate, linked against `libduckdb`, finds the extensions; the same binary against plain DuckDB does not |
| `loadable-extensions` | where a version has extensions that can only be loaded (duckpgq on 1.4): each is loaded into the DuckDB of the release, runs its smoke test, and the SQL fails without it |
| `<check>-1_4`, `<check>-1_5` | each of the above for the other versions of DuckDB, on every nixpkgs (`previous-all-extensions-1_4`, `stable-rust-consumer-1_5`, `loadable-extensions-1_4`) |
| `example-extension` | the extension of `templates/extension` is linked into DuckDB as a user of the flake would, is loaded without `INSTALL`, and passes its smoke test (on unstable only, since the mechanism is the same for every nixpkgs) |

Counting what is loaded is the check that matters. CMake carries on without an
extension it could not build, and says so in a line that is easy to miss.

The checks above build DuckDB several times, each with its test suite: about two hours
with 12 cores for all three nixpkgs. A free hosted GitHub runner has 4 cores and a
six-hour limit, so run them yourself with `nix flake check`. GitHub Actions
(`.github/workflows/ci.yml`) runs what does not need a DuckDB build: style, evaluation
for every system without import from derivation, every extension's source and the pins
check of every version, and CMake configuring DuckDB for each version on each nixpkgs.

DuckDB's own test suite runs in `installCheckPhase`, as in nixpkgs. Some tests cannot
pass in this build, and each is listed with its reason in the build log (and in
`pkgs/duckdb/extensions/default.nix`): tests that need the network, tests that assert
an extension is absent, and C++ tests that cannot run with `postgres_scanner` or
`spatial` loaded, or with `psql` linked in 2.0 (it switches its grammar on in every connection). Tests that need something different run in their own invocation instead.

## Developing

- `dev-keep-going` builds everything without the test suite; `dev-check` and
  `dev-rust-check` run the checks against it; `dev-configure` stops after CMake.
- For tests, build `unittest` once in a directory you keep (`nix develop .#duckdb-all`,
  then unpack, patch, configure and `ninja test/unittest`), and rerun single tests
  or relink with a subset of the extensions in a minute. That is how the test
  failures were attributed to individual extensions.
- Flakes see only tracked files; stage new ones.

## Not done

- Fully static (`pkgsStatic`, musl) builds.
- Other platforms. Only x86_64-linux has been built; aarch64-linux and
  aarch64-darwin are untried.
- Size: `libduckdb.so` with all 28 is 911 MB, mostly lance's DataFusion stack. Link
  only what you use.
- The Python modules marked "not built" in [the table above](#python-module): six of the
  nine pairs. Not built is not the same as not working; nothing is known about them.
- The aws extension of the CLI and the Rust library, which has the
  [race described above](#aws-two-databases-opened-at-the-same-time) without the lock the
  Python module of 2.0 has.

## License

[Apache-2.0](../LICENSE) for the Nix code and scripts in this repository. DuckDB, the
extensions and the Rust crates it builds are not part of it and keep their own
licenses.
