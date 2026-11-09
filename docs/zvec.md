# zvec, an in-process vector database, for Nix

[zvec](https://github.com/alibaba/zvec) (Apache-2.0) describes itself as "a lightweight,
lightning-fast, in-process vector database". This repository builds it from source as two
packages, and **almost everyone wants `zvec-c`**: the latest release as a shared C library, with
a header and a pkg-config file. It is also the library that the Rust crates of zvec's own team
link.

`zvec` is the other package, and you probably do not need it. It has no C API: it is the static
core libraries at an older commit, and it exists only because the `vector_search` extension of
[NeuG](neug.md) is built on exactly those. Use it to build something the way NeuG does.

| Package | What you get | Version | Use it for |
|---|---|---|---|
| `zvec-c` | `libzvec_c_api.so`, a C header, a pkg-config file | v0.8.1, the latest release | C programs, and Rust through zvec's own crates |
| `zvec` | four static libraries and their C++ headers | commit `fea2481` (2026-07-20), NeuG's | extensions built the way NeuG's `vector_search` is |

Contents: [Get it](#get-it) · [Use it](#use-it) ([C](#the-c-library), [Rust](#rust),
[static libraries](#the-static-libraries)) · [Things to know](#things-to-know) ·
[What is in it](#what-is-in-it) · [For maintainers and auditors](#for-maintainers-and-auditors)
([pins](#pins-and-update-scripts), [build](#how-zvec-c-is-built), [checks](#checks),
[without io_uring](#without-io_uring), [left out](#left-out-on-purpose)) ·
[Open items](#open-items)

## Get it

```sh
nix build github:levigross/engram#zvec-c    # the C library, its header and pkg-config file
nix build github:levigross/engram#zvec      # the static libraries (see above: you probably do not need them)
```

- `stable-` (26.05) and `previous-` (25.11) in front of the name give the same packages for those
  nixpkgs (`#stable-zvec-c`, `#previous-zvec-c`). Both packages are built and
  [checked](packaging.md#glossary) on all three.
- From your own flake: `lib.zvec-c pkgs` and `lib.zvec pkgs`, taken from this flake as an input
  (the [README](../README.md) shows how). The overlay `overlays.default` adds `zvec` and `zvec-c`.
- Only x86_64-linux with glibc is built ([why](TODO.md#zvec)).
- `zvec-c` compiles zvec together with Arrow and RocksDB, which takes minutes, not seconds
  ([times](#evidence-build-times)).
- Development only: `dev-configure-zvec-c` stops after CMake has configured, and
  `dev-keep-going-zvec-c` builds past failures to show every error of a build at once.

## Use it

### The C library

```sh
cc prog.c $(pkg-config --cflags --libs zvec_c_api) -o prog     # with buildInputs = [ zvec-c ]
```

```c
#include <stdio.h>
#include <zvec/c_api.h>

int main(void) {
  puts(zvec_get_version());                 /* v0.8.1, with the v */
  return zvec_check_version(0, 8, 0) ? 0 : 1;   /* is the library at least this version? */
}
```

- The library exports the `zvec_*` functions of `c_api.h` and nothing else: collections and their
  schemas, fields, documents, queries (with filters, and grouped), index parameters, the
  configuration. [How many](#zvec-c-library) at v0.8.1.
- It carries its C++ runtime inside (linked statically) and needs only the C library (`libc`,
  `libm`, `libdl`, `librt`). Your program needs no libstdc++ and cannot bring one that disagrees.
- `zvec_get_version()` returns `v0.8.1`, with the v. `zvec_check_version(major, minor, patch)`
  says whether the library is at least that version.

**Reading files.** The library chooses one way to read files, once per process: io_uring if the
kernel lets it make a ring, otherwise libaio if it can load `libaio.so.1`, otherwise `pread`.
`zvec_get_io_backend_type()` says which.

- Many systems have no io_uring: kernels built without it, the sysctl
  `kernel.io_uring_disabled`, the default seccomp profile of Docker since 25.0.
- This package provides no libaio (the library loads it with `dlopen`; io_uring is raw system
  calls, with no liburing). With neither, the library reads with `pread` and logs
  `no async I/O backend available`. To get libaio, put it on the library path.
- All three ways work and are tested ([Without io_uring](#without-io_uring)). The speed of
  `pread` is not measured: the library itself says that "performance may be degraded".

### Rust

The crates `zvec-rust-sys` and `zvec-rust` 0.8.0 on crates.io are **the zvec team's own**
([zvec-ai/zvec-rust](https://github.com/zvec-ai/zvec-rust), tag v0.8.0, Apache-2.0): safe bindings
over the C library, with the declarations written by hand and no bindgen. This repository writes
no binding code for zvec, unlike for [NeuG](neug.md#rust). It provides the library they link and
a program that uses them, `examples/zvec-rust-consumer`, built by
`nix/zvec/rust-checks/consumer.nix`:

```nix
pkgs.rustPlatform.buildRustPackage {
  # ...
  buildInputs = [ zvec-c ];                  # for its RUNPATH, see below
  env = zvec-c.rustEnv // {                  # ZVEC_AUTO_BUILD = "0"
    ZVEC_LIB_DIR = "${zvec-c}/lib";
    ZVEC_INCLUDE_DIR = "${zvec-c}/include";
  };
}
```

with `zvec-rust = { version = "=0.8.0", default-features = false }` in `Cargo.toml`. A trimmed
piece of the program (collection, document, search with a filter):

```rust
zvec_rust::initialize(None)?;                    // the caller does this, not the crate
let schema = CollectionSchema::builder("consumer")
    .add_indexed_field("price", DataType::Int32, IndexParams::invert(true, false)?)
    .add_vector_field(
        "embedding",
        DataType::VectorFp32,
        4,
        IndexParams::hnsw(MetricType::L2, 16, 200)?,
    )
    .build()?;
let c = Collection::create_and_open(path, &schema, None)?;
let mut doc = Doc::new()?;
doc.try_set_pk("doc_1")?;
doc.add_i32("price", 70)?;
doc.add_vector_f32("embedding", &[0.1, 0.0, 0.0, 0.0])?;
c.insert(&[&doc])?;
let mut query = SearchQuery::new("embedding", &[0.1, 0.0, 0.0, 0.0], 5)?;
query.set_filter("price >= 50")?;
for hit in c.query(&query)? { println!("{:?} {}", hit.get_pk(), hit.get_score()); }
```

- **Turn the default feature `bundled` off.** Its build script downloads a library with `curl`,
  with no check of what it gets, or clones zvec and builds it, whenever `ZVEC_LIB_DIR` has no
  library. The build also sets `ZVEC_AUTO_BUILD=0` (`zvec-c.rustEnv` does), so that a mistake in
  that directory is an error of the linker and not a download.
- **Put `zvec-c` in `buildInputs`.** The build script emits no [RUNPATH](packaging.md#glossary)
  (its comment says why: one emitted there would apply only to its own crate). The RUNPATH of the
  program comes from the linker wrapper of Nix, which puts the directory of every build input in
  it. Without it the program does not start.
- **Rust cannot run a grouped query or set the PQ quantizer.** The crates bind neither (a
  `GroupBySearchQuery` can be built, and has no method to run it). The C library has both. Which
  functions: [`zvec-rust-abi`](#zvec-rust-abi). More about the crates under
  [Things to know](#things-to-know).

### The static libraries

For building an extension the way NeuG's `vector_search` does. The components of zvec (metrics,
storage, index builders) register themselves in static initializers that nothing refers to.
**Link the three zvec libraries with `-Wl,--whole-archive`**, as NeuG's extension does; linked as
ordinary libraries, the registry is empty and every attempt to make an index fails.

```sh
c++ -std=c++17 -DNDEBUG -I$zvec/include prog.cc -o prog \
  -Wl,--whole-archive $zvec/lib/libzvec_core.a $zvec/lib/libzvec_turbo.a $zvec/lib/libzvec_ailego.a \
  -Wl,--no-whole-archive $zvec/lib/libroaring.a -pthread -ldl -lrt
```

- Compile against the headers of this package, not upstream's: with GCC 15 or later, upstream's
  headers make every small parameter value (an integer, a float, a bool) read back as 0
  ([the repair](#the-header-repair)).
- `GetDocCount()` of an index returns twice the number of vectors added. The searches show that
  nothing is stored twice. The cause is not known ([`zvec-library`](#zvec-library)).

## Things to know

- **Rust: the crates were made for zvec v0.8.0-beta2**, 30 commits before v0.8.1, and run here
  against v0.8.1. The header differs by additions only. Nothing in the crates checks the version or the
  ABI of the library at run time; [`zvec-rust-abi`](#zvec-rust-abi) does it at build time.
- **Rust: `Collection` is `Send` and `Sync`** in the crate, by an `unsafe impl` whose comment says
  that the C API documents its operations as thread-safe. The header of the C API says nothing
  about it (it has no "thread safe", "concurrent" or "reentrant"). That is the crate's claim, and
  it was not tested here.
- **Rust: close before you open again.** `Drop` closes a collection and never destroys it. A live
  handle blocks a second open of the directory (it holds a `LOCK` file), so call `try_close`
  first, as the example does before it opens the collection again.
- **Rust: no TLS.** Nothing in either lock file talks to a network, so the choice of `tls` that
  the other Rust programs of this repository have ([chDB](chdb.md#rust)) does not arise, and the
  example has no such argument ([`zvec-rust-lock-policy`](#zvec-rust-lock-policy)).
- **Two upstream issues are not worked around.** zvec issue #875: FastPFOR is compiled with
  `-msse4.1`, which is not portable. zvec issue #781: `group_by_query` returns nothing after a
  FLAT index with `use_id_map=false` is opened again.
- **No Python module.** zvec v0.8.1 has one; it is not built here.

## What is in it

- `zvec-c`: `lib/libzvec_c_api.so` (43.8 MB at v0.8.1 on unstable), `include/zvec/c_api.h` and
  `lib/pkgconfig/zvec_c_api.pc`. Its `passthru` has `rustEnv` (`ZVEC_AUTO_BUILD = "0"`, for Rust
  programs) and `cubePatch` ([the repair](#the-header-repair)).
- `zvec`: the static libraries `libzvec_core.a`, `libzvec_turbo.a`, `libzvec_ailego.a` and
  `libroaring.a`, and their headers: `include/zvec/{core,ailego,turbo}` and CRoaring's
  `roaring.h`, `roaring.hh` and `roaring64map.hh`. Its `passthru` has `cubePatch`.
- Both are built from `alibaba/zvec` with every submodule (`fetchSubmodules`), at the commits in
  [Pins](#pins-and-update-scripts).
- The Rust crates are not part of either package: they come from crates.io, pinned by hash, and
  are built by the program that uses them.

## For maintainers and auditors

You do not need any of this to use the packages. It says what is pinned and how, what differs
from upstream's build and why, what the checks prove, and what they leave out.

### Pins and update scripts

A [pin](packaging.md#glossary) fixes a source by commit and hash. Each script computes every hash
from the files themselves.

| What | Pinned at | Pin file | Update script |
|---|---|---|---|
| `zvec` | commit `fea2481` (2026-07-20) | `pkgs/zvec/pin.json` | `scripts/update-zvec.sh [commit]` |
| `zvec-c` | v0.8.1, commit `30d662d` (2026-11-06) | `pkgs/zvec-c/pin.json` | `scripts/update-zvec-c.sh [TAG]` |
| Rust crates | v0.8.0, commit `1683610` | `nix/zvec/rust-checks/pin.json` | `scripts/update-zvec-rust.sh [VERSION]` |

- **`zvec` is not the latest zvec.** The commit is the one that the release of NeuG in this
  repository has as its submodule, because the extension is compiled against exactly its
  headers. `scripts/update-zvec.sh` takes it from NeuG's pin, and the NeuG build fails if the
  headers it carries differ from this package's.
- **`zvec-c` is the latest release.** It is a second package, not a newer `zvec`, for two
  reasons: the pin of the first must stay NeuG's commit, and the C API is the whole database
  (collections, schemas, scalar fields and filters, vector indexes), which needs zvec's database
  layer: Arrow 21 with Parquet and its compute kernels, RocksDB and the ANTLR runtime. The first
  package never built any of them (its four libraries need none, see
  [How `zvec` is built](#how-zvec-is-built)).
- **The Rust crates** are `zvec-rust-sys` and `zvec-rust` 0.8.0, from the repository
  `zvec-ai/zvec-rust` at tag v0.8.0. That repository has zvec as a submodule at v0.8.0-beta2
  (`8397071`). `scripts/update-zvec-rust.sh` writes nothing unless: each `.crate` hashes to the
  sha256 that the crates.io API records; the `.cargo_vcs_info.json` of both crates names the
  commit that the tag names; every file of both crates is byte for byte the file of the
  repository at that tag; and the lock files name no network crate
  ([`zvec-rust-lock-policy`](#zvec-rust-lock-policy)).
- The script also keeps a copy of the repository's `Cargo.lock` in
  `nix/zvec/rust-checks/workspace.lock`, because a build cannot read one from a fetched source
  (that is import from derivation, which CI forbids). The copy is not called `Cargo.lock`:
  Dependabot takes every `Cargo.lock` for a Rust project and fails where no `Cargo.toml` is next
  to it.
- `scripts/update-zvec-c.sh` also checks that the functions `c_api.h` declares are the ones the
  version script exports, that the version can be given to CMake in place of git, and that every
  submodule the tree links was fetched.

### How zvec-c is built

`zvec-c` builds `zvec_c_api` of zvec v0.8.1 (`BUILD_C_BINDINGS`, from the sources with every
submodule). zvec wants a git checkout and a network, and the sandbox has neither. The build
downloads nothing; the seven Arrow archives below are fetched by Nix first, each by its hash.

- `git` is a build input: zvec's CMake applies the patches of its thirdparty projects with
  `git apply` and keeps a marker file for each that is done (cppjieba's too). Outside a checkout
  `git apply` does nothing, and the build would configure and fail later without saying why. The
  package asserts after the configure step that the four markers of the projects it relies on
  exist, so that a patch that was not applied fails the build there.
- Arrow's `ExternalProject` downloads seven archives while it builds: boost 1.88.0 (the CMake
  tarball), thrift 0.22.0, zlib 1.3.1, rapidjson 232389d4, re2 2022-06-01, utf8proc v2.10.0 and
  xsimd 13.0.0. The package gives each, as a fixed-output derivation, through the
  `ARROW_<NAME>_URL` variables that Arrow reads, and Arrow checks the hash a second time.
  `scripts/update-zvec-c.sh` takes each version and sha256 from Arrow's own `versions.txt` and
  fails unless the archive from its upstream has that hash.
- `CMAKE_POLICY_VERSION_MINIMUM=3.5` is set in the environment as well as on the command line:
  the nested CMake projects see the environment only, and CMake 4 refuses their old minimum.
- RocksDB 8.1.1 uses `uint64_t` without including `<cstdint>`, which GCC 15 and later no longer
  let pass (zvec issue #144; not fixed in v0.8.1). `NIX_CFLAGS_COMPILE` is `-include stdint.h`,
  as an environment variable because a CMake flag with a space in it is split by the CMake hook
  of Nix, and as `stdint.h` because C and C++ both have it. Without it, RocksDB built with
  GCC 16.2 fails in three files (`db/blob/blob_file_meta.cc`, `trace_replay/trace_record.cc` and
  `trace_replay/trace_record_result.cc`: `'uint64_t' has not been declared`); that is how it was
  found to be needed, not a guess.
- The inner build of Arrow uses as many jobs as the machine has processors, whatever the build
  was told, and its compute kernels take 1.5 to 3 GB each. A patch
  (`pkgs/zvec-c/arrow-build-cores.patch`) caps it to half of `NIX_BUILD_CORES`.
- `WITH_LIBURING=OFF`, since RocksDB uses liburing if it finds it.
- The [header repair](#the-header-repair).
- `.gitmodules` of v0.8.1 names a submodule, `thirdparty/aio/libaio-0.3`, that the tree does not
  link (a stale entry). The update script notes it and checks that every submodule the tree does
  link was fetched.

The library as built:

- It exports exactly the functions of the header, through a version script
  (`src/binding/c/exported_symbols.lds`).
- It links its C++ runtime statically: upstream's CMake does when it finds a static libstdc++,
  which it does under Nix.
- The source has no git history, so the build gives the version to CMake
  (`OVERRIDE_GIT_DESCRIBE`); without it the library reports `v0.0.0`.
- Its RUNPATH has the entries `$ORIGIN/../lib64:$ORIGIN/../lib:$ORIGIN` that upstream's CMake
  puts there, beside the directory of glibc. They are left as they are.
- libaio is loaded with `dlopen`, is not provided, and has no RUNPATH entry; io_uring is made of
  raw system calls, with no liburing.

#### Evidence: build times

- `zvec`: about a minute on unstable.
- `zvec-c`: about 4.5 minutes with 14 cores on unstable (GCC 16.2), about 7.5 minutes with 6 cores
  on 26.05 (GCC 15.3), and it also builds on 25.11 (GCC 14.3).

### How zvec is built

The same targets and flags as NeuG's own build of zvec (`zvec_core zvec_ailego zvec_turbo
roaring`, static, C++17), as a package of its own instead of a project inside the NeuG build. Of
everything zvec carries, Arrow and RocksDB among it, these four libraries need none: the rest is
configured and not built. The source tree is not a git checkout, so what zvec asks of one is done
in `postPatch`: the patches of three of its thirdparty projects (and the markers that tell its
CMake they are applied), a git version that nothing reads, and `librt`, which glibc has had
inside libc since 2.34.

### The header repair

One patch is applied to zvec's own source (`pkgs/zvec/cube-storage.patch`). It fixes a bug of
zvec, not of the build.

A `Cube`, the value of a parameter (`ailego::Params`), keeps a value that fits in a pointer (an
integer, a float, a bool) in the storage of a pointer member: it writes the value there with a
placement new typed as the value, and reads the member as a pointer when the Cube is moved. GCC 15
and later go by the types of the accesses, take a store of an `unsigned int` not to change a
`void *`, and drop it. Every parameter of such a type then reads back as 0, with no error:
`Params::set("chunk_count", 20u)` followed by `get` gives 0. Four of zvec's own unit tests
(`multi_chunk_cluster_test`, `opt_kmeans_cluster_test`, `diskann_searcher_test`,
`hnsw_sparse_builder_test`) failed on it, two with a segmentation fault.

The patch has the small policy copy the bytes with `memcpy`, which may alias anything, for a type
that is trivially copyable (all of them that a parameter has). Other types are made in place as
before: zvec's own `cube_test`, which counts the copies and moves of such a type, caught a first
version that did not leave them alone.

- The headers in `include/` of `zvec` are the repaired ones, so a program that uses `Params` with
  them is right too. NeuG's tree carries a copy of the same headers, and its build applies the
  same patch, so that the extension and the libraries do not have two versions of one inline
  function.
- The bug is still in v0.8.1, and `zvec-c` has the same repair as
  `pkgs/zvec-c/cube-storage.patch`. The patch above does not apply to that version (three
  context lines gained `override`), so it is the same change with the context of this one.
  [`zvec-c-params`](#zvec-c-params) shows it works.

#### Evidence: the Cube bug

- A small program shows it with GCC 15.3 and 16.2 at `-O2` and `-O3`. GCC 13.5, GCC 14.4 and
  clang 21.1 give 20, and so does GCC 16 with `-O0`, `-fno-strict-aliasing` or
  `-fno-devirtualize`.
- The dumps of GCC 16 show how: its summary of `SmallCubePolicy<unsigned int>::assign` is a store
  of 32 bits of the type `unsigned int`, and the pointer that the Cube is moved by is taken from
  before that call, as 0.
- The four tests pass built with `-fno-strict-aliasing`, and pass with the patch alone.

### Checks

Checks are named `zvec-<check>`, `zvec-c-<check>` and `zvec-rust-<check>`; the other nixpkgs put
their prefix in front (`stable-zvec-c-library`, ...). Each has a
[control](packaging.md#glossary): something that must fail. The checks of `zvec-c` and
`zvec-rust` pass on unstable, on 26.05 and on 25.11. Most suites run in three
[modes](packaging.md#glossary) of reading files, as the machine has it and without io_uring
(libaio, pread): [Without io_uring](#without-io_uring). Counts below are for the pinned
versions.

| Check | What it proves |
|---|---|
| [`zvec-library`](#zvec-library) | The static libraries link with `--whole-archive` and work; linked plainly, they fail. |
| [`zvec-params`](#zvec-params) | Small parameter values read back as set, with the repaired headers. |
| [`zvec-tests`](#zvec-tests) | zvec's own unit tests of the three zvec libraries pass. |
| [`zvec-c-library`](#zvec-c-library) | The C library has the right files and exports exactly the functions of its header. |
| [`zvec-c-params`](#zvec-c-params) | The parameter check again, for v0.8.1. |
| [`zvec-c-io-backends`](#zvec-c-io-backends) | Without io_uring the library picks libaio or pread, and the wrapper really blocks io_uring. |
| [`zvec-c-tests`](#zvec-c-tests) | zvec's own test of the C API passes, in all three modes. |
| [`zvec-c-examples`](#zvec-c-examples) | zvec's C examples run and pass, in all three modes. |
| [`zvec-c-core-tests`](#zvec-c-core-tests) | zvec's unit tests of ailego, core and turbo pass, in all three modes. |
| [`zvec-c-db-tests`](#zvec-c-db-tests) | zvec's unit tests of the database layer pass, in all three modes. |
| [`zvec-rust-lock-policy`](#zvec-rust-lock-policy) | No lock file has a crate of TLS or HTTP, or one from git. |
| [`zvec-rust-consumer`](#zvec-rust-consumer) | A Rust program on the crates uses a collection end to end against `zvec-c`. |
| [`zvec-rust-abi`](#zvec-rust-abi) | Every function the crates declare is exported by the library. |
| [`zvec-rust-tests`](#zvec-rust-tests) | The zvec team's own tests of the two crates pass, in four passes. |

CI builds none of this (the library and the tests do not fit a hosted runner). Its `evaluate` job
(`nix flake check --no-build`, without import from derivation) does evaluate the packages and
checks named here.

#### zvec-library

- Links the libraries with `--whole-archive` and uses them for real: a flat index of 1000 vectors
  of 8 dimensions must return exactly what brute force returns, an HNSW index must return the
  vector itself at distance 0 with the results in ascending order, and a roaring bitmap is used
  as a filter.
- Control: the same program linked as ordinary libraries must fail, and it does, because the
  registry of components is empty.
- The document count of an index (`GetDocCount()`) is twice the number of vectors added, for
  both kinds of index, also with the header repair. The searches show that nothing is stored
  twice, so the check prints the count and does not assert it. Why it is twice was not looked
  into.

#### zvec-params

- It is the program that found the [bug](#the-header-repair): for each of the eleven types that
  fit in a pointer (`bool`, the integers of 8 to 64 bits, signed and unsigned, `float` and
  `double`) a parameter is set and must read back as what was set, built with `-O3` against the
  headers of the package.
- Control: where the compiler is GCC 15 or later, the same program of `uint32_t` against the
  headers as upstream has them must fail, and it does (`set 20, read 0`). GCC 13, GCC 14 and
  clang do not lose the value, so the control is left out for them.

#### zvec-tests

- Runs zvec's own unit tests of the libraries this package builds, with `ctest`: ailego (60
  tests), core (34) and turbo (1). All pass. The core takes about eleven minutes, ten of them for
  `hnsw_sparse_streamer_test`.
- The tests of the database layer (`tests/db`) are not run for this package: see
  [Left out on purpose](#other-tests-and-programs-not-run). `zvec-c-db-tests` runs the database
  layer of v0.8.1 for the other package.
- The googletest of zvec (1.10.0) lacks an include of `<cstdint>` that GCC 15 and later need, so
  the check adds it to its copy.

#### zvec-c-library

- The package holds the three files (library, header, pkg-config file) and no other.
- The library needs the C library and nothing else.
- The functions of the header, those of zvec's own list of exports
  (`src/binding/c/exported_symbols.lds`, a version script) and those the shared object defines
  are the same set: **380 functions**.
- `zvec_get_version` and `zvec_check_version` agree with the pin.
- A program built with the header and `-lzvec_c_api`, and one built with the flags of pkg-config,
  find the library by their RUNPATH.
- Controls: a library with `libstdc++` added to its `NEEDED` is refused; so are a header with one
  declaration less, a version that is not the library's, a program without its RUNPATH, and
  pkg-config without the package in its path.

#### zvec-c-params

The check of [`zvec-params`](#zvec-params) for this version: a parameter of each of the eleven
types that fit in a pointer reads back as what was set, built with `-O3` against the headers with
the repair. Where the compiler is GCC 15 or later, the headers as upstream has them must fail with
`uint32_t`, and do (`set 20, read 0`).

#### zvec-c-io-backends

- Shows which I/O the library uses where the kernel has no io_uring, and that `no-iouring` does
  what it says: for each error (`ENOSYS`, `EPERM`), with libaio on the library path or not, the
  probe (`zvec_get_io_backend_type`) says `libaio` or `pread` and the description says why. Where
  the machine has io_uring, it says io_uring.
- Controls: each clause of the comparison (the error, the backend, the description) is shown to
  fail by itself; a probe without the wrapper is not taken for one with it; the children of the
  command are filtered too; and the wrapper used wrongly exits with 2 and runs nothing. With a
  wrapper that filters nothing the check fails.

#### zvec-c-tests

- Runs zvec's own test of the C API (`tests/c/c_api_test.c`), compiled against the installed
  library the way an application is: the header of the package, `-lzvec_c_api`, the library found
  by the RUNPATH the linker records, with the warning flags of upstream's CMake and `-Werror`.
- `main` calls **82 test functions** (counted from the source: the file defines more, one of them
  commented out in `main` and one only a wrapper of tests that `main` calls). The output must name
  exactly those 82 and say `Total tests: 82, Passed: 82, Failed: 0`, and the version string of the
  pin. The test has **5999 assertions** that pass and none that fail.
- It runs three times, as the machine has its I/O and in the two modes without io_uring
  ([Without io_uring](#without-io_uring)), and passes in all.
- Controls: one assertion flipped in a copy (the compatibility of versions) fails at its own line
  and at no other, and the program without its RUNPATH does not start.

#### zvec-c-examples

- Runs the 7 programs of zvec's `examples/c`, each compiled against the installed library and run
  in a directory of its own. `diskann_example` is among them: upstream's CI does not run it, and
  it passes here.
- The list is compared with the sources and with upstream's `CMakeLists.txt`, so an example that
  upstream adds fails the check.
- A pass is: nothing on stderr, none of the marks of failure the examples print,
  `example completed`, and the version of the pin in the output of `optimized_example` (an
  example returns 0 even where it prints that a step failed).
- Each example runs in the three modes too. `diskann_example` prints the backend that reads its
  index, which must be the one of the mode, and its search returns the same in all three.
- Recorded, not asserted: the query of `doc_example` filters on `'string_field_0'` where its
  documents hold `test_string_N`, so it returns nothing and the loop that verifies its results
  checks nothing.
- Controls: an example in a directory that cannot be written to fails and says so, and one
  without its RUNPATH does not start.

#### zvec-c-core-tests

- Runs zvec's unit tests of `ailego` (43 test programs), `core` (81) and `turbo` (29), **153**
  in all, built from the source, patches and flags of the package and run with `ctest`. All pass.
  About 11 minutes of tests for each run, almost all for `core`.
- Some tests skip themselves, and the check lists them
  ([the list](#the-tests-that-skip-themselves)). A test that is not on the list and skips, or one
  that is on it and does not, fails the check.
- The suite runs three times, as the machine has its I/O and in the two modes without io_uring
  ([Without io_uring](#without-io_uring)), each with the skips its mode adds, and passes in all.
  The logs of the `pread` mode have the library's warning that it has no async backend, and those
  of the `libaio` mode do not. libaio is on the library path in the first run, so that the tests
  of the code that loads it run.
- Some tests skip for want of an instruction set (AVX-512, VNNI, FP16) or because the user can
  write to a file that is meant to be read-only. The list is that of an x86_64 CPU with AVX-512
  and VNNI, built as an unprivileged user, as the builders here are; on another CPU the check
  names the difference.
- The check requires every test that CMake registers to have a file and every file to be
  registered, except for [one Windows test](#other-tests-and-programs-not-run).
- One test is run again when it fails: `diskann_mobile_compat_test`
  ([why](#a-test-that-fails-on-its-first-run)).
- Control: one expectation made wrong in `bit_string_helper_test`, built again, must fail.

#### zvec-c-db-tests

- Runs zvec's unit tests of the database layer (`tests/db`), the code that the C API is, built and
  run as `zvec-c-core-tests` is, in the same three modes: **74 test programs**, all pass in each
  and none skips itself. About 10 minutes of tests for each run.
- The 75th test file, `utf8_acp_test`, is for Windows with MSVC and is not registered; the check
  says so ([details](#other-tests-and-programs-not-run)). `data_generator` and
  `collection_optimizer`, which tests start, are built as well.
- The 72 tests that can run together take about 200 seconds. The 2 whose names match `recovery`
  (they kill processes and wait for time to pass) run one at a time afterwards, which takes a few
  minutes more.
- `perf_bench_test` skips its 17 cases unless it is told to run them, and some of them check what
  the queries return, so it is told to (`ZVEC_RUN_PERF_BENCH=1`), on 5000 documents and one
  iteration, not 100000 and 30.
- Control: one expectation made wrong in `cgroup_util_test` must fail.

#### zvec-rust-lock-policy

- The lock file of the example (3 packages) and the copy of the lock file of the crates'
  repository (104 packages) have no crate of TLS or HTTP (no openssl, rustls, ring, reqwest,
  ureq, hyper, curl or tokio) and none from git. The update script says the same.
- Control: the function that says so (`nix/zvec/rust-checks/policy.nix`) is shown to refuse a
  lock file with `openssl-sys`, at evaluation.

#### zvec-rust-consumer

- Builds `examples/zvec-rust-consumer` on the crates against `zvec-c` and runs it. The version of
  the library is the pin's. It makes a collection with an `int32` field `price` (inverted index),
  a string `label` and a 4-dimensional fp32 vector (HNSW, L2), and 100 documents.
- It searches for the 5 nearest of `doc_42`: itself first, at distance 0, the others ascending;
  the second is `doc_43` at 1.3225, which is a squared L2 distance. The same query with
  `price >= 50` has hits that all have a price of 50 or more.
- It fetches a document and every field round-trips; deletes one; runs `optimize`; closes and
  opens the collection again, with the same count and the same nearest hit; and a path that is
  not a collection and a malformed filter are `Err` and not panics.
- The program must have the RUNPATH of `zvec-c`.
- Controls: the same program told to expect another version of the library fails, and without its
  RUNPATH it does not start.

#### zvec-rust-abi

- The **375 functions** that `zvec-rust-sys` declares are all exported by the library
  ([how many it exports](#zvec-c-library)).
- The **5 that the crates do not bind** are exactly this list: `zvec_collection_group_by_query`,
  `zvec_group_results_free`, `zvec_index_params_get_quantizer_pq`,
  `zvec_index_params_set_quantizer_pq` and `zvec_doc_add_field_by_struct`. So Rust has no grouped
  queries and no PQ quantizer.
- Controls: a function the library lacks, a function missing from the list of the five, and one
  of the five that is bound each fail the check. A newer crate that binds one of the five fails it
  until the list is changed.

#### zvec-rust-tests

- Runs the zvec team's own tests of the two crates, from their repository at the tag, with its
  `Cargo.lock`: `cargo test --lib --tests --doc`, in four passes: with the default features, with
  `--no-default-features`, and with the default features in the two modes without io_uring
  ([Without io_uring](#without-io_uring)).
- Each pass has **209 tests** that pass and none ignored. 209 is the number of `#[test]` functions
  in the sources: 119 unit tests, 80 in 6 integration test files and 10 of the hermetic tests of
  the build script. The test programs are compared with the manifest.
- Each pass also has 7 documentation tests: 6 pass (five are only compiled, and one is
  `compile_fail`, which passes by not compiling) and 1 is `ignore`d.
- No test skips itself (the crate prints "skipping" when the library lacks DiskANN or RaBitQ; none
  did here).
- Not run: [two helper members and the benchmarks](#other-tests-and-programs-not-run).
- Controls: one test with a wrong expectation fails at that test; with the variables of the
  linker wrapper taken away the same tests link with a right `ZVEC_LIB_DIR` and fail to link
  (`cannot find -lzvec_c_api`) with an empty one, and nothing is downloaded either way.

### Without io_uring

The library chooses how it reads files once per process (`src/ailego/io/io_backend_def.h`); the
order is in [Reading files](#the-c-library). Every use of the library by the checks goes through
io_uring on the machine that builds them, if its kernel has it, so the other two ways have their
own runs.

`nix/zvec/io` has `no-iouring`, a small program that installs a seccomp filter (libseccomp) under
which `io_uring_setup`, `io_uring_enter` and `io_uring_register` fail, in the command it starts and
in all that this starts. The modes:

| Mode | The call fails with | libaio | The library selects |
|---|---|---|---|
| `default` | not blocked | whatever the check provides | what the machine has: io_uring, where its kernel has it |
| `libaio` | `ENOSYS`, as on a kernel built without io_uring | on the library path | `libaio` |
| `pread` | `EPERM`, as with the sysctl or a container profile | not found | `pread` |

- The error changes one log line of the library and nothing else: `zvec-c-io-backends` runs all
  four combinations of error and libaio.
- The filter needs no privilege and works in the sandbox of a Nix build.
- Before it starts the command, `no-iouring` makes the call itself and exits with 3 if it does not
  fail with the error asked for, so a filter that is not in effect cannot go unnoticed.
- What this does not reproduce is the kernel itself: a program sees the error of the call and
  nothing else of a kernel without io_uring.

**Results.** Everything passes in all three modes. Each check asserts the mode it is in, from the
library's own account of its backend, and the suites also from what they log.

| Check | What runs in each mode |
|---|---|
| [`zvec-c-tests`](#zvec-c-tests) | the test of the C API |
| [`zvec-c-examples`](#zvec-c-examples) | every example; `diskann_example` prints the backend of the mode |
| [`zvec-c-core-tests`](#zvec-c-core-tests) | the unit tests of ailego, core and turbo |
| [`zvec-c-db-tests`](#zvec-c-db-tests) | the unit tests of the database layer |
| [`zvec-rust-tests`](#zvec-rust-tests) | the crates' tests, with the default features, once in each mode without io_uring |

What changes from mode to mode is which tests skip themselves, because they ask for what the mode
lacks: the last three rows of [the table of skipped tests](#the-tests-that-skip-themselves).

### Left out on purpose

What the checks do not run, and why.

#### The tests that skip themselves

Where a test skips itself, the check lists it, with the reason that the source of the test gives.
20 skip in every mode; the last three rows are the ones a mode adds.

| Tests | Skipped in | Reason |
|---|---|---|
| `ThreadQueue.MultiThreadWithHighPriority` | every mode | disabled upstream: `GTEST_SKIP()` first in the test |
| `TestMaxIndexSize` of `FlatStreamerTest`, `HnswStreamerTest`, `HnswSparseStreamerTest` | every mode | disabled upstream the same way |
| 15 NEON tests of turbo, and the NEON case of `Backends/RawInt8Simd.FullSignedRangeTailsBatchesAndLongVectors` | every mode | need AArch64 (NEON) or an unavailable ISA |
| `IoUringLoaderTest.ReadsBatchAndZeroPadsExpectedShortRead`, `.WritesScatteredBatch` | `libaio`, `pread` | no ring can be made |
| `DiskAnnLibAioDeathTest.WorkerContextOutlivesStaticDestructors` | `pread` | libaio cannot be loaded |
| `BufferPoolTest.AioAdmissionUsesFreeCapacityBeforeEviction` | `pread` | no asynchronous backend at all |

What each test says, and where:

- `ThreadQueue.MultiThreadWithHighPriority`: "TODO(windows): add it back"
  (`tests/ailego/parallel/thread_queue_test.cc:113`).
- The three `TestMaxIndexSize` tests: `tests/core/algorithm/flat/flat_streamer_test.cc:1520`,
  `hnsw/hnsw_streamer_test.cc:1694`, `hnsw_sparse/hnsw_sparse_streamer_test.cc:1210`.
- The NEON tests: "requires AArch64" or "lacks NEON"
  (`tests/turbo/turbo_{neon_batch,neon_distance,fp16_quantizer,fp32_quantizer,pq_fast_quantizer,pq_int4_quantizer,pq_int8_quantizer}_test.cc`),
  and for the NEON case of `RawInt8Simd`, "ISA unavailable on this build/CPU"
  (`turbo_raw_int8_test.cc:157`).
- The two `IoUringLoaderTest` tests: "io_uring is unavailable" when a ring cannot be made
  (`tests/ailego/io/iouring_loader_test.cc:66`, `:97`).
- `DiskAnnLibAioDeathTest...`: "libaio is not installed" when `dlopen` finds none
  (`tests/core/algorithm/diskann/diskann_libaio_lifetime_test.cc:87`).
- `BufferPoolTest.AioAdmissionUsesFreeCapacityBeforeEviction`: "no asynchronous backend is
  available" (`tests/ailego/buffer/vector_page_table_test.cc:1904`).

#### Other tests and programs not run

- **Tests for Windows.** CMake registers every test file but two. `diskann_file_reader_windows_test`
  is added for WIN32 only (`tests/core/algorithm/diskann/CMakeLists.txt`), and
  `tests/db/utf8_acp_test` is registered for Windows with MSVC
  (`tests/db/utf8_acp/CMakeLists.txt`). The checks require every registered test to have a file,
  and every file to be registered but those.
- **The 59 tests of the database layer (`tests/db`) for `zvec`.** They are of code that is not
  part of that package: they link the library zvec, which needs Arrow 21 (built from source with
  downloaded dependencies), RocksDB and protobuf, and the extension of NeuG does not use that
  layer. [`zvec-c-db-tests`](#zvec-c-db-tests) runs the database layer of v0.8.1 for the other
  package.
- **Two helper members of the crates' workspace:** `zvec-build` (published as `zvec-rust-build`)
  and `zvec-rpath-smoke`, which this repository does not provide. **The criterion benchmarks**
  measure and do not test.
- **No control for `zvec-params` on a GCC before 15, or on clang.** They do not lose the value, so
  there is nothing to show failing ([`zvec-params`](#zvec-params)).

### A test that fails on its first run

`diskann_mobile_compat_test` (`tests/core/algorithm/diskann`) builds a DiskANN index of 64 vectors,
dumps it to a file and searches it. Its test `BuildDumpLoadAndSearch` fails now and then, at lines
343 and 374 of the file: the search of the freshly built index does not return the nearest
vector (the query is 12.1 and the vector is 12), and the search with a filter returns nothing. It
passes when it is run again.

**What the check does.** When this is the only test to fail, `zvec-c-core-tests` runs it again,
three times at most, and prints that it did (`running them again`). Any other failure is final.
The retry was tried on a small `ctest` project of four tests: one that fails its first run is run
again and passes; one that fails every time still fails the check after the third try; and a
failure of a test that is not named fails at once, also next to one that is. The final runs of
the check on the three nixpkgs, which are the ones this page describes, needed no second run.

**What was measured,** with the test program of the check's own build, run by hand in the sandbox
of a Nix build, on a machine whose builds are on ZFS:

- 12 test programs were built, 8 with 26.05, 2 with unstable and 2 with 25.11, one at a time, and
  each was run in a loop of 40 to 2000 times, alone and with 32 busy processes beside it (about
  14 000 runs after the first ones). 9 of the 12 failed on their first run, with these lines (6 of
  8 on 26.05, 2 of 2 on unstable, 1 of 2 on 25.11); no run after a first run failed. Where the
  loop said which run failed (2 of the 9), it was the first. Two more programs, built with
  `-ftrivial-auto-var-init=zero` and `=pattern`, did not fail, which is too few to say anything.
  `MALLOC_PERTURB_` (a few hundred runs) and the size of the environment (2050 runs) did not make
  a later run fail either.
- The check failed at it on 26.05 three times in a row, at the first run that `ctest` made, with
  the same lines. The complete runs of the check that followed (one under another name, one under
  its own, and the final one on each nixpkgs) passed. Why it failed three times in a row is not
  known.
- Not the compiler: GCC 14.3, 15.3 and 16.2 all did it, and a build with `-O1`, `-O2` or
  `-fno-strict-aliasing` passed in the one run each that was made.

**What is not known.** The builder starts its k-means from `std::random_device`
(`src/ailego/algorithm/lloyd_cluster.h`) and builds with two threads, so the index is not the same
every time. Whether a search right after a build can really miss the nearest vector (a defect of
the library), or the test is at fault, or the file system, was not found out.

## Open items

See [TODO](TODO.md#zvec).
