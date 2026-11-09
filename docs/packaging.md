# How the engines are packaged

This page is for people who change this repository or want to know how far to trust it. To use
an engine, start from the [README](../README.md) and the page of that engine.

Contents: [Glossary](#glossary) · [The shape of an engine](#the-shape-of-an-engine) ·
[Updating a pin](#updating-a-pin) · [Checks](#checks) · [CI](#ci) · [Rust and TLS](#rust-and-tls) ·
[Adding an engine](#adding-an-engine) · [Style](#style)

## Glossary

| Word | Meaning here |
|---|---|
| **pin** | An upstream revision (release, tag or commit) recorded in a `pin.json` with the hash of its files, which a script computes. |
| **three nixpkgs** | nixpkgs unstable (packages under their own name), 26.05 (`stable-` prefix) and 25.11 (`previous-` prefix). `stable-chdb` is `chdb` built with 26.05. |
| **built and checked** | Built, and its checks run, with that nixpkgs. A package can be *offered* without having been built; the engine's page says which. |
| **not built** | Nothing was run. It does not mean "fails". |
| **line** | A release series of DuckDB: major.minor, such as 1.5. 1.5.2 is a version in the 1.5 line. |
| **linked** / **loadable** | A *linked* extension is compiled into DuckDB. A *loadable* one is a `.duckdb_extension` file that you `LOAD`. |
| **check** | A derivation under `checks.<system>` in the flake. `nix build .#checks.x86_64-linux.<name>` runs it; it passes if the build succeeds. |
| **negative control** | The part of a check that must fail: a wrong expectation, a missing library, a read-only directory. |
| **mode** (zvec) | One way of running zvec's tests: as the machine has its I/O, or with io_uring taken away. See [zvec](zvec.md#without-io_uring). |
| **RUNPATH** | The list of directories a program searches for its shared libraries, stored in the program. Nix puts the store paths of the libraries there. |
| **sandbox** | The isolated environment where a Nix build runs: no network, no home directory, only the declared inputs. |

## The shape of an engine

Every engine has the same parts:

| Part | Where |
|---|---|
| The package | `pkgs/<engine>/` |
| The pin | `pkgs/<engine>/pin.json` (DuckDB: `pkgs/duckdb/versions/<version>/`) |
| The script that makes the pin | `scripts/update-<engine>.sh` |
| The overlay, packages and checks of the flake | `nix/<engine>/{default,overlay,packages,checks}.nix` |
| Rust consumers and examples | `examples/<engine>-rust-consumer/` (DuckDB: `examples/rust-consumer`) |
| The page | `docs/<engine>.md` |

Rules every engine follows:

- **Hashes are computed, not copied.** The update script fetches the files and hashes them, and
  compares with what the upstream publishes where it publishes anything.
- **Nothing is fetched at build time or at run time.** Where an upstream's build wants a git
  checkout, a network or `/usr/bin/env`, the Nix build does it instead, and the engine's page says so.
- **Checks run the engine** and each has something that must fail (a negative control).
- **What is known and what is not is written down with the evidence.** An open item goes to
  [TODO](TODO.md), and an item that has been done is deleted from it.

## Updating a pin

| Script | Pins |
|---|---|
| `scripts/update-duckdb.sh` | A DuckDB release and every extension at the commit that release pins |
| `scripts/update-chdb.sh` | chDB's prebuilt library, its wheel and the pure-Python wheel |
| `scripts/update-chdb-rust.sh` | The lock files of the chDB Rust example, one for OpenSSL and one for rustls |
| `scripts/update-neug.sh` | A NeuG release and its sources with every submodule |
| `scripts/update-zvec.sh` | zvec at the commit NeuG has as its submodule (static libraries) |
| `scripts/update-zvec-c.sh` | A zvec release and the archives Arrow downloads while it is configured (C library) |
| `scripts/update-zvec-rust.sh` | The zvec team's Rust crates and a copy of their repository's lock file |
| `scripts/availability.sh` | Prints which DuckDB extensions are missing on which version and nixpkgs, and why |

The header of each script says what it pins and how it checks it.

## Checks

`nix flake check` builds every check. For DuckDB that takes hours, so run one check at a time:

```sh
nix build .#checks.x86_64-linux.<name>          # unstable
nix build .#checks.x86_64-linux.stable-<name>   # 26.05
nix build .#checks.x86_64-linux.previous-<name> # 25.11
nix flake show                                  # all the names
```

Checks are named `<engine>-<what>` (`chdb-library`, `zvec-c-tests`, `neug-python-tests`). What each
one proves, its negative controls and what it leaves out are on the engine's page under *Checks*.
Upstream's own test suites run as checks wherever that is possible. Every test that is left out is
left out for a reason that is written next to it.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs what fits a hosted runner:

| Job | What it does |
|---|---|
| `lint` | `scripts/lint.sh`: formatting, dead code, shell and workflow lint |
| `evaluate` | Every package and check of every system evaluates, without import from derivation (as Hydra has it) |
| `sources` | Fetches every source and runs the `extension-pins` checks of DuckDB |
| `configure` | CMake configures DuckDB with every extension, per version per nixpkgs (nine jobs), without compiling |
| `chdb` | Builds chDB (a prebuilt binary) and runs its library check |

CI builds no DuckDB, NeuG or zvec: a full build with the test suites takes hours and does not fit
a hosted runner. They are built and checked on the maintainer's machine, one build at a time.

## Rust and TLS

Some Rust crates of an engine bring a TLS stack. People need one or the other, so the Rust programs of
this repository are built with a choice of `tls`, `"openssl"` or `"rustls"`, and a feature of a crate
that needs TLS at run time uses rustls. How that is done for chDB, and what was checked, is in
[chDB](chdb.md#rust). zvec's crates have no TLS or HTTP crate, so the choice does not arise there; the
check `zvec-rust-lock-policy` keeps it so.

## Adding an engine

Copy the shape above: `pkgs/<engine>` with a `pin.json`, `scripts/update-<engine>.sh`,
`nix/<engine>/{default,overlay,packages,checks}.nix`, an entry in `nix/overlay.nix`, `nix/lib.nix`
and `flake.nix`, and a page in `docs/` with the same sections as the other pages. Flakes see only
tracked files, so `git add` new files before you build.

## Style

`scripts/lint.sh` (run it in `nix develop`) checks `nixfmt`, `deadnix`, `statix`, `shellcheck` on every
tracked `.sh` file, and `actionlint`. CI runs the same script.
