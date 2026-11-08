# zvec, an in-process vector database, for Nix

[zvec](https://github.com/alibaba/zvec) (Apache-2.0) describes itself as "a lightweight,
lightning-fast, in-process vector database". Here it is packaged twice: as the libraries that
the `vector_search` extension of [NeuG](neug.md) is built on, and as its C API, a shared library
that the Rust crates of zvec's own team link ([Rust](#rust)).

| | |
|---|---|
| `zvec` | the static libraries `libzvec_core.a`, `libzvec_turbo.a`, `libzvec_ailego.a` and `libroaring.a`, and their headers (`include/zvec/{core,ailego,turbo}` and CRoaring's `roaring.h`, `roaring.hh`, `roaring64map.hh`) |
| `zvec-c` | zvec v0.8.1's C API: `lib/libzvec_c_api.so` (43.8 MB on unstable), `include/zvec/c_api.h` and `lib/pkgconfig/zvec_c_api.pc` |

```sh
nix build github:levigross/engram#zvec
nix build github:levigross/engram#zvec-c
```

There are also `stable-` and `previous-` (26.05 and 25.11) of both, built and tested as well,
and `lib.zvec pkgs` and `lib.zvec-c pkgs` for your own flake. `zvec` builds in about a minute on
unstable. `zvec-c` builds in about 4.5 minutes with 14 cores on unstable (GCC 16.2), in about 7.5
minutes with 6 cores on 26.05 (GCC 15.3), and also on 25.11 (GCC 14.3). `dev-configure-zvec-c`
stops after CMake has configured, and `dev-keep-going-zvec-c` builds past failures to show every
error of a build at once (both for development).

## Two packages, two pins

**`zvec` is not the latest zvec.** The commit is the one that the release of NeuG in this
repository has as its submodule (2026-07-20, `fea2481`), because the extension is compiled
against exactly its headers; `scripts/update-zvec.sh` takes it from NeuG's pin, and the NeuG
build fails if the headers it carries differ from this package's. It has no C API.

**`zvec-c` is the latest release**, v0.8.1 (commit `30d662d`, 2026-11-06), pinned in
`pkgs/zvec-c/pin.json` by `scripts/update-zvec-c.sh [TAG]`. It is a second package, not a newer
`zvec`, for two reasons: the pin of the first must stay NeuG's commit, and the C API is the whole
database (collections, schemas, scalar fields and filters, vector indexes), which needs zvec's
database layer: Arrow 21 with Parquet and its compute kernels, RocksDB and the ANTLR runtime.
The first package never built any of them (its four libraries need none, see below).

## How `zvec` is built

The same targets and flags as NeuG's own build of zvec (`zvec_core zvec_ailego zvec_turbo
roaring`, static, C++17), as a package of its own instead of a project inside the NeuG build.
Of everything zvec carries, Arrow and RocksDB among it, these four libraries need none: the
rest is configured and not built. The source tree is not a git checkout, so what zvec asks of
one is done in `postPatch`: the patches of three of its thirdparty projects (and the markers
that tell its CMake they are applied), a git version that nothing reads, and `librt`, which
glibc has had inside libc since 2.34.

### A repair of the headers

One patch is applied to zvec's own source (`pkgs/zvec/cube-storage.patch`), and it is a bug of
zvec, not of the build. A `Cube`, the value of a parameter (`ailego::Params`), keeps a value that
fits in a pointer (an integer, a float, a bool) in the storage of a pointer member: it writes the
value there with a placement new typed as the value, and reads the member as a pointer when the
Cube is moved. GCC 15 and later go by the types of the accesses, take a store of an `unsigned
int` not to change a `void *`, and drop it. Every parameter of such a type then reads back as 0,
with no error: `Params::set("chunk_count", 20u)` followed by `get` gives 0, and four of zvec's
own unit tests (`multi_chunk_cluster_test`, `opt_kmeans_cluster_test`, `diskann_searcher_test`,
`hnsw_sparse_builder_test`) failed on it, two with a segmentation fault.

- A small program shows it with GCC 15.3 and 16.2 at `-O2` and `-O3`. GCC 13.5, GCC 14.4 and
  clang 21.1 give 20, and so does GCC 16 with `-O0`, `-fno-strict-aliasing` or `-fno-devirtualize`.
  The dumps of GCC 16 show how: its summary of `SmallCubePolicy<unsigned int>::assign` is a
  store of 32 bits of the type `unsigned int`, and the pointer that the Cube is moved by is
  taken from before that call, as 0.
- The four tests pass built with `-fno-strict-aliasing`, and pass with the patch alone.
- The patch has the small policy copy the bytes with `memcpy`, which may alias anything, for a
  type that is trivially copyable (all of them that a parameter has). Other types are made in
  place as before: zvec's own `cube_test`, which counts the copies and moves of such a type,
  caught a first version that did not leave them alone.
- The headers in `include/` are the repaired ones, so a program that uses `Params` with them is
  right too. NeuG's tree carries a copy of the same headers, and its build applies the same
  patch, so that the extension and the libraries do not have two versions of one inline function.
- The bug is still in v0.8.1, and `zvec-c` has the same repair as `pkgs/zvec-c/cube-storage.patch`.
  The patch above does not apply to that version (three context lines gained `override`), so it
  is the same change with the context of this one. `zvec-c-params` shows it works.

## Using the static libraries

The components of zvec (metrics, storage, index builders) register themselves in static
initializers that nothing refers to. **Link the three zvec libraries with
`-Wl,--whole-archive`**, as NeuG's extension does; linked as ordinary libraries, the
registry is empty and every attempt to make an index fails.

```sh
c++ -std=c++17 -DNDEBUG -I$zvec/include prog.cc -o prog \
  -Wl,--whole-archive $zvec/lib/libzvec_core.a $zvec/lib/libzvec_turbo.a $zvec/lib/libzvec_ailego.a \
  -Wl,--no-whole-archive $zvec/lib/libroaring.a -pthread -ldl -lrt
```

## The C library

`zvec-c` builds `zvec_c_api` of zvec v0.8.1 (`BUILD_C_BINDINGS`, from the sources with every
submodule). `c_api.h` declares 380 functions: collections and their schemas, fields, documents,
queries (with filters, and grouped), index parameters, the configuration.

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

- It exports the 380 `zvec_*` functions of the header and nothing else (a version script,
  `src/binding/c/exported_symbols.lds`): the header, the script and the symbols the library
  defines are the same set (`zvec-c-library`).
- It links its C++ runtime statically (upstream's CMake does when it finds a static libstdc++,
  which it does under Nix) and needs the C library only: `libc`, `libm`, `libdl`, `librt`. A
  program that links it needs no libstdc++ and cannot bring one that disagrees.
- `zvec_get_version()` returns `v0.8.1`. The source has no git history, so the build gives the
  version to CMake (`OVERRIDE_GIT_DESCRIBE`); without it the library reports `v0.0.0`.
- Its `RUNPATH` has the entries `$ORIGIN/../lib64:$ORIGIN/../lib:$ORIGIN` that upstream's CMake
  puts there, beside the directory of glibc. They are left as they are.
- It loads libaio with `dlopen`, and libaio is not provided. By the source, DiskANN falls back
  to `pread` where it finds none, and io_uring is made of raw system calls (no liburing). The
  library was not tried on a kernel without io_uring.

### What the build needed

zvec wants a git checkout and a network, and the sandbox has neither. The build downloads
nothing; the seven archives below are fetched by Nix first, each by its hash.

- `git` is a build input: zvec's CMake applies the patches of its thirdparty projects with
  `git apply` and keeps a marker file for each that is done (cppjieba's too). Outside a checkout
  `git apply` does nothing, and the build would configure and fail later without saying why. The
  package asserts after the configure step that the four markers of the projects it relies on
  exist, so that a patch that was not applied fails the build there.
- Arrow's `ExternalProject` downloads seven archives while it builds: boost 1.88.0 (the CMake
  tarball), thrift 0.22.0, zlib 1.3.1, rapidjson 232389d4, re2 2022-06-01, utf8proc v2.10.0 and
  xsimd 13.0.0. The package gives each, as a fixed-output derivation, through the `ARROW_<NAME>_URL`
  variables that Arrow reads, and Arrow checks the hash a second time. `scripts/update-zvec-c.sh`
  takes each version and sha256 from Arrow's own `versions.txt` and fails unless the archive
  from its upstream has that hash.
- `CMAKE_POLICY_VERSION_MINIMUM=3.5` is set in the environment as well as on the command line:
  the nested CMake projects see the environment only, and CMake 4 refuses their old minimum.
- RocksDB 8.1.1 uses `uint64_t` without including `<cstdint>`, which GCC 15 and later no longer
  let pass (zvec issue #144; not fixed in v0.8.1). `NIX_CFLAGS_COMPILE` is `-include stdint.h`,
  as an environment variable because a CMake flag with a space in it is split by the CMake hook of
  Nix, and as `stdint.h` because C and C++ both have it. Without it, RocksDB built with GCC 16.2
  fails in three files (`db/blob/blob_file_meta.cc`, `trace_replay/trace_record.cc` and
  `trace_replay/trace_record_result.cc`: `'uint64_t' has not been declared`); that is how it
  was found to be needed, not a guess.
- The inner build of Arrow uses as many jobs as the machine has processors, whatever the build
  was told, and its compute kernels take 1.5 to 3 GB each. The package caps it to half of
  `NIX_BUILD_CORES`.
- `WITH_LIBURING=OFF`, since RocksDB uses liburing if it finds it.
- The repair of the headers (above).
- `.gitmodules` of v0.8.1 names a submodule, `thirdparty/aio/libaio-0.3`, that the tree does not
  link (a stale entry). The update script notes it and checks that every submodule the tree does
  link was fetched.

x86_64-linux only: on arm and riscv FastPFOR fetches simde while it is configured, which a
sandbox cannot do.

## Rust

The crates are `zvec-rust-sys` and `zvec-rust` 0.8.0 on crates.io, **the zvec team's own**
([zvec-ai/zvec-rust](https://github.com/zvec-ai/zvec-rust), tag v0.8.0, Apache-2.0): safe bindings
over the C API, with the declarations written by hand and no bindgen. This repository writes no
binding code for zvec, unlike for [NeuG](neug.md#rust). What it provides is the library they link
and a program that uses them, `examples/zvec-rust-consumer`, built by `nix/zvec/rust.nix`:

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

with `zvec-rust = { version = "=0.8.0", default-features = false }`. A trimmed piece of the
program (collection, document, search with a filter):

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

The pin is `pkgs/zvec-rust/pin.json`, made by `scripts/update-zvec-rust.sh [VERSION]`, which
writes nothing unless: each `.crate` hashes to the sha256 that the crates.io API records; the
`.cargo_vcs_info.json` of both crates names the commit that the tag names; every file of both
crates is byte for byte the file of the repository at that tag; and the lock files name no
network crate (below). It also keeps a copy of the repository's `Cargo.lock` in
`pkgs/zvec-rust/workspace.lock`, because a build cannot read one from a fetched source (that is
import from derivation, which CI forbids). It is not called `Cargo.lock`: Dependabot takes every
`Cargo.lock` for a Rust project and fails where no `Cargo.toml` is next to it.

What was learned by using the crates:

- **Their default feature `bundled`** makes the build script of `zvec-rust-sys` download a
  library with `curl`, with no check of what it gets, or clone zvec and build it, whenever
  `ZVEC_LIB_DIR` has no library. The example turns the feature off and the build sets
  `ZVEC_AUTO_BUILD=0` too, so that a mistake in that directory is an error of the linker and not
  a download.
- **The build script emits no rpath** (its comment says why: one emitted there would apply only
  to its own crate). The `RUNPATH` of the program comes from the linker wrapper of Nix, which puts
  the directory of every build input in it. That is why `zvec-c` is in `buildInputs`;
  `zvec-rust-consumer` shows the program has it and does not start without it.
- **Nothing in the crates checks the version or the ABI** of the library. `zvec-rust-abi` does.
- **The crates were made for zvec v0.8.0-beta2** (the submodule of their repository, `8397071`),
  30 commits before v0.8.1. The header differs by additions only. Five functions of the library
  are not bound by the crates: `zvec_collection_group_by_query`, `zvec_group_results_free`,
  `zvec_index_params_get_quantizer_pq`, `zvec_index_params_set_quantizer_pq` and
  `zvec_doc_add_field_by_struct`. So **Rust cannot run a grouped query or set the PQ quantizer**
  (a `GroupBySearchQuery` can be built, and has no method to run it).
- **`Collection` is `Send` and `Sync`** by an `unsafe impl` whose comment says that the C API
  documents its operations as thread-safe. The header of the C API says nothing about it (it has
  no "thread safe", "concurrent" or "reentrant"). That is the crate's claim. It was not tested
  here: neither the example nor the tests of the crates (read for it) start a thread of their own.
- `Drop` closes a collection and never destroys it. A live handle blocks a second open of the
  directory (it holds a `LOCK` file), so `try_close` first, as the example does before it
  opens the collection again.

**TLS.** Nothing in either lock file talks to a network: no openssl, rustls, ring, reqwest,
ureq, hyper, curl or tokio, and no source from git. The check `zvec-rust-lock-policy` and the
update script both say so, so the choice of `tls` that the other Rust programs of this repository
have ([chDB](chdb.md#rust)) is a no-op here. `nix/zvec/rust.nix` takes the same argument
(`"none"` by default, `"rustls"`, `"openssl"`) for the day that changes.

## Checks

Named `zvec-<check>`, `zvec-c-<check>` and `zvec-rust-<check>` (`stable-zvec-c-library`, ...). Each
has something that must fail. Those of `zvec-c` and `zvec-rust` pass on unstable, on 26.05 and on 25.11.

### zvec

`zvec-library` links the libraries that way and uses them for real: a flat
index of 1000 vectors of 8 dimensions must return exactly what brute force returns, an HNSW
index must return the vector itself at distance 0 with the results in ascending order, and a
roaring bitmap is used as a filter. The same program linked as ordinary libraries must fail,
and it does, because the registry of components is empty.

The document count of an index (`GetDocCount()`) is twice the number of vectors added, for
both kinds of index, also with the repair of the headers. The searches show that nothing is
stored twice, so the count is printed by the check and not asserted. Why it is twice was not
looked into.

`zvec-params` is the program that found the bug above, one for each of the eleven types that fit
in a pointer: a parameter is set and must read back as what was set, built with `-O3` against the
headers of the package. Where the compiler is GCC 15 or later, the same program of `uint32_t`
against the headers as upstream has them must fail, and it does (`set 20, read 0`); GCC 13, GCC 14
and clang do not lose the value, so the control is left out for them.

`zvec-tests` runs zvec's own unit tests of the libraries this package builds, with `ctest`:
ailego (60 tests), core (34) and turbo (1), and all of them pass. The core takes about eleven
minutes, ten of them for `hnsw_sparse_streamer_test`. The 59 tests of the database layer
(`tests/db`) are of code that is not part of this package: they link the library zvec, which needs
Arrow 21 (built from source with downloaded dependencies), RocksDB and protobuf, and the extension
of NeuG does not use that layer. (`zvec-c-db-tests` runs the database layer of v0.8.1 for the
other package.) The googletest of zvec (1.10.0) lacks an include of `<cstdint>` that GCC 15 and
later need, so the check adds it to its copy.

### zvec-c

| | |
|---|---|
| `zvec-c-library` | the package holds the three files and no other; the library needs the C library and nothing else; the functions of the header, those of zvec's own list of exports and those the shared object defines are the same 380; `zvec_get_version` and `zvec_check_version` agree with the pin; a program built with the header and `-lzvec_c_api`, and one built with the flags of pkg-config, find the library by their `RUNPATH`. Controls: a library with `libstdc++` added to its `NEEDED` is refused, a header with one declaration less, a version that is not the library's, a program without its `RUNPATH`, and pkg-config without the package in its path |
| `zvec-c-params` | the check of `zvec-params` for this version: a parameter of each of the eleven types that fit in a pointer reads back as what was set, built with `-O3` against the headers with the repair. Where the compiler is GCC 15 or later, the headers as upstream has them must fail with `uint32_t`, and do (`set 20, read 0`) |
| `zvec-c-tests` | zvec's own test of the C API (`tests/c/c_api_test.c`), compiled against the installed library the way an application is (the header of the package, `-lzvec_c_api`, the library found by the `RUNPATH` the linker records), with the warning flags of upstream's CMake and `-Werror`. `main` calls 82 test functions (counted from the source: the file defines more, one of them commented out in `main` and one only a wrapper of tests that `main` calls); the output must name exactly those 82 and say `Total tests: 82, Passed: 82, Failed: 0`, and the version string of the pin. It has 5999 assertions that pass and none that fail. Controls: one assertion flipped in a copy (the compatibility of versions) fails at its own line and at no other, and the program without its `RUNPATH` does not start |
| `zvec-c-examples` | the 7 programs of zvec's `examples/c`, each compiled against the installed library and run in a directory of its own. `diskann_example` is among them: upstream's CI does not run it, and it passes here. The list is compared with the sources and with upstream's `CMakeLists.txt`, so an example that upstream adds fails the check. A pass is also nothing on stderr, none of the marks of failure the examples print, `example completed`, and the version of the pin in the output of `optimized_example` (an example returns 0 even where it prints that a step failed). Recorded, not asserted: the query of `doc_example` filters on `'string_field_0'` where its documents hold `test_string_N`, so it returns nothing and the loop that verifies its results checks nothing. Controls: an example in a directory that cannot be written to fails and says so, and one without its `RUNPATH` does not start |
| `zvec-c-core-tests` | zvec's unit tests of `ailego` (43 test programs), `core` (81) and `turbo` (29), built from the source, patches and flags of the package and run with `ctest`: all pass. 19 tests skip themselves, and the check lists them, each with the line of the source that says why; one that is not on the list skipping, or one on it not skipping, fails the check. They are `ThreadQueue.MultiThreadWithHighPriority` and `TestMaxIndexSize` of the flat, HNSW and sparse HNSW streamers, which upstream disabled with `GTEST_SKIP()`, and 15 NEON tests of turbo, which need AArch64. libaio is on the library path of the tests, so that the tests of the code that loads it run (`DiskAnnLibAioDeathTest` skips itself where `dlopen` finds none). CMake registers every test file but one, `diskann_file_reader_windows_test`, which upstream's CMake adds for WIN32 only; the check requires every registered test to have a file and every file to be registered but that one. **One test is run again when it fails**: `diskann_mobile_compat_test` fails now and then on its first run, and passes when run again (see [below](#a-test-that-fails-on-its-first-run)), so when it is the only test to fail the check runs it again, three times at most, and prints that it did; any other failure is final. About 12 minutes of tests, 11 of them for `core`. Control: one expectation made wrong in `bit_string_helper_test`, built again, must fail |
| `zvec-c-db-tests` | zvec's unit tests of the database layer (`tests/db`), the code that the C API is, built and run as `zvec-c-core-tests` is: 74 test programs, all pass and none skips itself. The 75th test file, `utf8_acp_test`, is for Windows with MSVC (its `CMakeLists.txt` returns at once elsewhere) and is not registered; the check says so. `data_generator` and `collection_optimizer`, which tests start, are built as well. The 72 tests that can run together take about 200 seconds; the 2 whose names match `recovery` (they kill processes and wait for time to pass) run one at a time afterwards, which takes a few minutes more. `perf_bench_test` skips its 17 cases unless it is told to run them, and some of them check what the queries return, so it is told to (`ZVEC_RUN_PERF_BENCH=1`, on 5000 documents and one iteration, not 100000 and 30). About 10 minutes of tests. Control: one expectation made wrong in `cgroup_util_test` must fail |

### The Rust crates

| | |
|---|---|
| `zvec-rust-lock-policy` | the lock file of the example (3 packages) and the copy of the lock file of the crates' repository (104 packages) have no crate of TLS or HTTP and none from git. The function that says so (`nix/zvec/rust-policy.nix`) is shown to refuse a lock file with `openssl-sys`, at evaluation |
| `zvec-rust-consumer` | `examples/zvec-rust-consumer`, built on the crates against `zvec-c` and run: the version of the library is the pin's; a collection with an `int32` field `price` (inverted index), a string `label` and a 4-dimensional fp32 vector (HNSW, L2); 100 documents; the 5 nearest of `doc_42` (itself first, at distance 0, the others ascending; the second is `doc_43` at 1.3225, which is a squared L2 distance); the same query with `price >= 50`, whose hits all have a price of 50 or more; a fetch that round-trips every field; a delete; `optimize`; close and open again, with the same count and the same nearest hit; a path that is not a collection and a malformed filter, which are `Err` and not panics. The program must have the `RUNPATH` of `zvec-c`. Controls: the same program told to expect another version of the library fails, and without its `RUNPATH` it does not start |
| `zvec-rust-abi` | the 375 functions that `zvec-rust-sys` declares are all exported by the library, which exports 380. The five that it does not bind are exactly the list [above](#rust). Controls: a function the library lacks, a function missing from the list of the five, and one of the five that is bound each fail the check. A newer crate that binds one of the five fails it until the list is changed |
| `zvec-rust-tests` | the zvec team's own tests of the two crates, from their repository at the tag, with its `Cargo.lock`: `cargo test --lib --tests --doc`, in two passes, with the default features and with `--no-default-features`. Each pass has 209 tests that pass and none ignored (209 is the number of `#[test]` functions in the sources: 119 unit tests, 80 in 6 integration test files and 10 of the hermetic tests of the build script), and the 7 documentation tests: 6 pass (five are only compiled, and one is `compile_fail`, which passes by not compiling) and 1 is `ignore`d. No test skips itself (the crate prints "skipping" when the library lacks DiskANN or RaBitQ; none did here). The test programs are compared with the manifest. Not run: the two helper members of the workspace (`zvec-build`, which is published as `zvec-rust-build`, and `zvec-rpath-smoke`), which this repository does not provide, and the criterion benchmarks, which measure and do not test. Controls: one test with a wrong expectation fails at that test; with the variables of the linker wrapper taken away the same tests link with a right `ZVEC_LIB_DIR` and fail to link (`cannot find -lzvec_c_api`) with an empty one, and nothing is downloaded either way |

CI builds none of this (the library and the tests do not fit a hosted runner). Its `evaluate`
job (`nix flake check --no-build`, without import from derivation) does evaluate the packages and
checks named here.

### A test that fails on its first run

`diskann_mobile_compat_test` (`tests/core/algorithm/diskann`) builds a DiskANN index of 64
vectors, dumps it to a file and searches it. Its test `BuildDumpLoadAndSearch` fails now and then,
at lines 343 and 374 of the file: the search of the index that was just built does not return the
nearest vector (the query is 12.1 and the vector is 12), and the search with a filter returns
nothing. It passes when it is run again. What was measured, with the test program of the check's
own build, run by hand in the sandbox of a Nix build, on a machine whose builds are on ZFS:

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

The builder starts its k-means from `std::random_device` (`src/ailego/algorithm/lloyd_cluster.h`)
and builds with two threads, so the index is not the same every time. Whether a search right after
a build can really miss the nearest vector (a defect of the library) or the test is at fault, or
the file system, was not found out. The check runs this test again, three times at most, when it
is the only one to fail, and prints that it did (`running them again`); any other failure is
final. The retry was tried on a small `ctest` project of four tests: one that fails its first run
is run again and passes; one that fails every time still fails the check after the third try;
and a failure of a test that is not named fails at once, also next to one that is. The final runs
of the check on the three nixpkgs, which are the ones this page describes, needed no second run.

## Not done

- **Grouped queries and the PQ quantizer from Rust**: the crates, 0.8.0, bind neither (the five
  functions under [Rust](#rust)). The C API has them.
- The crates are tested against v0.8.1 though they were made for v0.8.0-beta2. The header differs
  by additions only, and their own tests and `zvec-rust-abi` show that what they bind works;
  they do not show that nothing changed in what the functions do.
- Two upstream issues are not worked around: #875 (FastPFOR is compiled with `-msse4.1`, which
  is not portable) and #781 (`group_by_query` returns nothing after a FLAT index with
  `use_id_map=false` is opened again).
- The Python module of zvec (v0.8.1 has one) is not built.
- The `zvec` static libraries stay at NeuG's commit.
- `libaio` is not provided, and nothing was tried on a kernel without io_uring (see
  [The C library](#the-c-library)).
- Any system but x86_64-linux with glibc.
- The failure of `diskann_mobile_compat_test` on its first run (above) is not explained, and the
  check runs the test again where it fails.
