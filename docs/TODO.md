# TODO

What is not done, not fixed or not known, for every engine. The pages of the engines say what
works; this page says what does not, and what nobody has looked at.

How to read it:

- **Known defects, not fixed**: something is wrong, usually upstream's, and this repository has not
  repaired it.
- **Not built or not tried (unknown)**: nothing was run. That is not the same as "fails".
- **Left out on purpose, worth revisiting**: a choice with a reason, which could change.
- **Follow-up work**: something worth doing and not started.
- **Chores**: housekeeping of the repository that has nothing to do with an engine.

Each item links to the place on an engine's page where the evidence is. When an item is done, delete
it from here, and from the page if it was mentioned there.

Contents: [Cross-cutting](#cross-cutting) · [DuckDB](#duckdb) · [chDB](#chdb) · [NeuG](#neug) · [zvec](#zvec)

## Cross-cutting

These apply to every engine.

### Not built or not tried (unknown)

- **aarch64-linux and aarch64-darwin.** `flake.nix` lists both systems and CI evaluates every output for
  them, but nothing was built there. Only x86_64-linux with glibc was built and checked. The
  engines' pages say what else stands in the way (chDB pins its aarch64-linux assets and has not run
  them; zvec's FastPFOR fetches `simde` on arm).
- **Fully static builds (`pkgsStatic`, musl).** Only glibc was built.

### Follow-up work

- **A binary cache.** Nothing is cached, so the first build of an engine compiles it, and for DuckDB runs
  its test suite. [Packaging](packaging.md#checks)
- **Build the big checks in CI.** The full builds of DuckDB, NeuG and zvec with their test suites take
  hours (DuckDB: about two hours with 12 cores for all three nixpkgs), and a free hosted runner has 4
  cores and a six-hour limit. They run on the maintainer's machine, one at a time. CI covers what fits
  ([CI](packaging.md#ci)); `nix flake check` runs the rest.
- **The `chdb` CI job depends on GitHub's release downloads.** It failed with HTTP 504 for the
  chdb-core asset on three attempts in a row, and passed when re-run later. Nothing in the repository
  was at fault.

### Chores

- **Delete the remote branch `origin/parity`.** Everything in it is in `main`. It was left in place
  because deleting a branch of the public repository was not asked for.

## DuckDB

### Known defects, not fixed
- **The overlay breaks Python packages that depend on `duckdb`.** With `overlays.default` applied, `python3Packages.duckdb` and `python3Packages.ibis-framework` fail to evaluate with "cannot coerce a function to a string", from the `pythonModule` function in the passthru of `pkgs/duckdb/default.nix` (line 229 at this commit). nixpkgs' Python builder (`validatePythonMatches` in `mk-python-derivation.nix`) takes any dependency with a `pythonModule` attribute for a Python library and calls `toString` on it. `python3Packages.duckdb` would also fail without that, by design: the overlay removes `pythonHash`, which is the hash of the module of the DuckDB that nixpkgs ships. Met while running chDB's tests, which import ibis when it is there. Evaluated and traced, not fixed. [Evidence](duckdb.md#as-an-overlay)
- **aws: two databases opened at the same moment can corrupt the heap, in the CLI and the Rust library.** Seen only through Python, where it failed in 14 of 60 runs. The 2.0 Python module has a mutex that prevents it (`pkgs/duckdb/python.nix`); the CLI, the Rust library and the 1.x modules do not. Workaround: open one database or connection before starting threads that open more. [Evidence](duckdb.md#aws-two-databases-opened-at-the-same-time)
- **One nondeterministic failure of DuckDB's core suite, 2.0.0 on 25.11, not isolated.** One of 7800 test cases failed once, `test/api/test_query_result_format_buffer.cpp:108` (`REQUIRE(report.saw_blocked_sink)`): a producer thread of the result stream was meant to park and did not. The same derivation built again on the same machine passed the whole suite (7769 test cases run, 31 skipped) and all four checks. The test is not left out; a failure of it alone is worth a second run. [Evidence](duckdb.md#duckdb-builds)
- **`libduckdb.so` with all 28 extensions of 2.0.0 is 911 MB**, mostly lance's DataFusion stack. The advice is to link only what you use; nothing was done about the size. [Page](duckdb.md#things-to-know)

### Not built or not tried (unknown)
- **Python modules: 6 of the 9 (version, nixpkgs) pairs are "not built".** Built: 2.0.0 on unstable, 1.5.2 and 1.4.3 on 26.05. Not built: 2.0.0 on 26.05 and 25.11, 1.5.2 on unstable and 25.11, 1.4.3 on unstable and 25.11. They are the same packages on another nixpkgs; nothing is known about them, which is not the same as failing. [Evidence](duckdb.md#python-module-test-results)
- **The copy of `nanobind` 3 (`pkgs/duckdb/nanobind.nix`) is untried**, because the 2.0.0 module has not been built on 26.05 or 25.11, the two nixpkgs that need the copy. [Evidence](duckdb.md#python-module-test-results)
- **The aws extension of 1.5.2 and 1.4.3 was not read**, so whether they have the race above is unknown. [Evidence](duckdb.md#aws-two-databases-opened-at-the-same-time)
- **duckpgq on 1.4: the command lines were not run against the registry's build outside the `loadable-extensions-1_4` check**, and the extension has not been loaded from the Python module of 1.4. The session with the build made here runs as written. [Evidence](duckdb.md#duckpgq-on-14-what-was-run)

### Left out on purpose, worth revisiting
- **DuckDB's suite: the test that attaches a database over HTTP, for httpfs in 1.4 and 1.5** (`test/sql/attach/remote_file_concurrently.test`) needs network access. [Table](duckdb.md#left-out-on-purpose)
- **DuckDB's suite: "Test catalog versioning" with the vortex of 1.4 linked in.** It expects catalog version 1 once the database is open, and with the vortex of 1.4 alone it is not; it passes with the vortex of 1.5 and with every other extension. [Table](duckdb.md#left-out-on-purpose)
- **DuckDB's suite: network tests**, such as `test/sql/logging/http_response_log_redaction.test`, which installs an extension over HTTP. [Table](duckdb.md#left-out-on-purpose)
- **DuckDB's suite: tests that assert an extension is absent**, such as `test/extension/local_extension_coverage.test` (sqlite_scanner) and a test that expects EPSG:4326 to be unknown (spatial). They cannot hold once the extension is linked in. [Table](duckdb.md#left-out-on-purpose)
- **DuckDB's suite: C++ tests that cannot run with postgres_scanner (22), spatial (1) or psql (4, on 2.0) loaded.** The postgres_scanner ones run a `LogicalPlanStatement`, which cannot be copied; the psql ones count grammars, and psql switches its grammar on in every connection. [Table](duckdb.md#left-out-on-purpose)
- **The 2.0.0 Python module leaves out tests that fail without any extension linked in**: four with polars, one writing a `list_view` column to Parquet, a time zone test (`utcoffset returned an invalid timedelta`), `test_8522`, `test_fetch_arrow_reader`, two interrupt tests that hang when their file runs, and three groups that crash the interpreter (Arrow `string_view` with pyarrow 24, shutdown with daemon threads that scan). Several are not looked into; they are out because they fail without our extensions, not because they are known to be wrong tests. [Table](duckdb.md#tests-left-out-of-the-20-python-module)
- **The 2.0.0 Python module leaves out tests that expect a bare DuckDB**: two for aws (default secrets, threads that outlive a closed database) and one for threads at import (a jemalloc background thread with spatial, mysql_scanner, postgres_scanner or sqlite_scanner linked in). Also `tests/fast/expression/test_expression_generated.py`, which reads the `duckdb/` directory the check removes. [Table](duckdb.md#tests-left-out-of-the-20-python-module)
- **vortex's committed C header may lag what upstream regenerates.** The build script regenerates it with a tool that needs the monorepo layout, so the build uses the committed header; the smoke test only catches it lagging. [Page](duckdb.md#the-rust-extensions)
- **`example-extension` is checked on unstable only**, since the mechanism is the same for every nixpkgs. [Page](duckdb.md#checks)

### Follow-up work
- **Fix the overlay's break of Python packages**: provide `python3Packages.duckdb` in the overlay (the module of this flake is `python3-duckdb`), and probably rename the `pythonModule` function of the passthru, which nixpkgs reads as the marker of a Python library.
- **Patch the aws extension itself**, so that every build has the lock, not only the Python module of 2.0.
- **Delete the five azure SDK packages copied from 26.05** (`pkgs/duckdb/azure-sdk-for-cpp`, used for nixpkgs 25.11) when 25.11 has them. [Page](duckdb.md#what-differs-by-version-and-nixpkgs)
- **Delete `pkgs/duckdb/nanobind.nix`** when 26.05 and 25.11 have `python3Packages.nanobind_3`. [Page](duckdb.md#what-differs-by-version-and-nixpkgs)
- **An allowlist of extension owners in the `extension-pins` check**. [Page](duckdb.md#checks)
- **A provenance section**: which extensions come from whom. Only `duckpgq-registry` is a prebuilt binary. [Page](duckdb.md#the-extensions)
- **A `duckdb-1_4-duckpgq` wrapper** that preloads the registry's build, so that duckpgq on 1.4 needs no `LOAD`. [Page](duckdb.md#graph-queries-on-duckdb-14-duckpgq)

## chDB

### Known defects, not fixed
- **The C++ header `chdb.hpp` does not link.** `chdb.hpp` calls `CHDB::connect_chdb_with_exception`, which `libchdb.so` of v26.9.0 does not export (it exports the C function `connect_chdb`). The four C++ examples of chdb-core also write `chdb::` where the header's namespace is `CHDB`. `chdb-core-c-tests` records both failures: `runCppExamples` must fail. From C++ use `chdb.h`. [Evidence](chdb.md#things-to-know)
- **The binaries are not signed or attested.** The hash that `scripts/update-chdb.sh` checks proves only that the file is the one the release's `SHA256SUMS` (for the `chdb` wheel, the digest GitHub shows) lists. [Evidence](chdb.md#where-the-binaries-come-from)
- **The engine prints a warning with a stack trace in the Nix sandbox** that it cannot find the cgroup files. It is harmless, but eight tests of `chdb-core-python-tests` (seven in `test_stdout_noise.py`, one in `test_wasm_udf.py`) take it for noise on stderr and fail; where the files can be read they pass. The check requires exactly those eight to fail. [Evidence](chdb.md#fail-by-design)

### Not built or not tried (unknown)
- **Only x86_64-linux with glibc is built.** The aarch64-linux assets are pinned and untried; macOS is not offered. [Evidence](chdb.md#get-it)
- **CPUs without AVX.** The upstream's build flags were not read here, and the library was only run on machines that have AVX. [Evidence](chdb.md#things-to-know)
- **The upstream tests were built on unstable only.** `chdb-rust-tests`, `chdb-core-c-tests` and `chdb-datastore-tests` are offered on 26.05 and 25.11 too; `chdb-core-python-tests` is offered on unstable only, because `adbc-driver-manager` is missing from `python3Packages` on 26.05 and 25.11. `nix/chdb/checks/tests/default.nix` gates only that one check. [Evidence](chdb.md#upstreams-own-tests)
- **Real S3 is untried.** The stand-in store of `chdb-rust-consumer-s3` answers only `GET`, `PUT`, `ETag`s and the conditional `If-None-Match: *` and `If-Match`; it requires an `Authorization` header and checks no signatures. [Evidence](chdb.md#checks-of-this-repository)

### Left out on purpose, worth revisiting
- **The engine is not built from source,** which would make it auditable. chdb-core is a fork with about a gigabyte of source; by its build script it needs clang 21 and a nightly Rust, and it has 156 submodules. [Evidence](chdb.md#how-it-is-built)
- **`durable_s3` of `chdb-rust-tests` needs a bucket** (`CHDB_DURABLE_S3_BUCKET`) and skips itself; the stand-in store covers what it asks of S3. [Evidence](chdb.md#not-run)
- **36 tests of `chdb-core-python-tests` are skipped** because they need a remote ClickHouse, MinIO, MySQL, MongoDB or an AI provider. [Evidence](chdb.md#not-run)
- **Three modules of chdb-core are left out because they read from the Internet:** `test_delta_lake.py`, `test_issue60.py` and `test_on_df.py` (which downloads a file when it is imported). [Evidence](chdb.md#not-run)
- **One leak test of `chdb-core-c-tests` skips itself** because it needs an AddressSanitizer build. [Evidence](chdb.md#not-run)
- **Four upstream benchmarks of `chdb-rust-tests` are `#[ignore]`d** in each of the two passes ("run with --release --ignored"). [Evidence](chdb.md#not-run)
- **Parts of `chdb-datastore-tests` are left out:** `TestRemoteClickHousePushdown` (2 tests, which send `CREATE OR REPLACE TABLE function remote(...)`, not SQL), `test_agents_smolagents` (`gradio` does not evaluate in nixpkgs), `tests/clickhouse_connect` (a separate pipeline upstream), and two tests that import duckdb or ibis and skip themselves because neither is installed (with the `duckdb` of the overlay, evaluating `ibis-framework` fails, see [the overlay](duckdb.md#as-an-overlay)). [Evidence](chdb.md#not-run)

### Follow-up work
- **Move to the engine the Rust crate asks for.** `chdb-rust` 2.1.0 is made for engine v26.11.0-rc.2, a pre-release; the pin stays on the release v26.9.0. With v26.9.0 the case `shutdown_after_mergetree_merges` of `runtime_faces` fails (`chdb_shutdown` is refused) and `chdb-rust-tests` requires that failure, so a newer engine makes the check fail until the exception is removed. [Evidence](chdb.md#fail-by-design)
- **The other bindings of chDB** (Go, Node.js, ...). [Evidence](chdb.md)

## NeuG

### Known defects, not fixed
- **Processes forked from one that has drawn a UUID draw the same UUIDs.** A defect of NeuG, still in upstream's main and not repaired here. Two read-only processes forked from one that opened a database can share a runtime directory, and the first to close removes it from under the other. One case of the C++ suite is left out for it; `neug-fork-uuid` fails when the library stops doing it, which is when to put the case back. [Evidence](neug.md#neug-fork-uuid)
- **A failed `CHECK` or `LOG(FATAL)` inside the engine ends the process.** The header of `neug_c.h` names two queries that reach one: a `shortestPath` over several labels and a `MERGE` of an unknown label. Callers that cannot afford that must run the engine in a process of its own. [Things to know](neug.md#things-to-know)
- **A database that is read and written allows one connection.** A second connection (`Connect`, `neug_conn_open`) is refused with an exception whose text ends with `Error Code: 4001`. An engine limit, not a defect of the packaging; listed because a user meets it. [C interface](neug.md#c-interface)
- **The C++ class has no accessor for the error code of an exception.** A second connection or a missing extension arrives in C as `NEUG_E_EXCEPTION` (10006) with the engine's text, which ends with its code; the code is not parsed out of a message. A wrong query has its own code (5001). [C interface](neug.md#c-interface)

### Not built or not tried (unknown)
- **The CHECK and LOG(FATAL) sites other than those two queries.** None was exercised. The header of `neug_c.h` says about 130 such sites and does not say what it counted; a `grep` of the source at 0.3.0 finds about 160 in 43 files. The two counts have not been reconciled. [Things to know](neug.md#things-to-know)
- **A program with its own yaml-cpp, antlr4 or utf8proc, loaded before `libneug.so`.** `libneug.so` exports symbols that mention them (819 of 34455 for yaml-cpp, 2514 for antlr4, 41 for utf8proc, at 0.3.0), so such a program would meet them. Not tried, and neither was a program with a protobuf of its own beside `libneug_c.so`. [Evidence](neug.md#neug-coexist)
- **`httpfs` reads over the network.** The extension loads; reading was not tried, as the sandbox has no network. The remote Parquet tests of the Python suite are left out for the same reason. [Left out](neug.md#left-out-on-purpose)
- **The two Python test datasets are not upstream's archives.** `modern_graph` and `tinysnb` are rebuilt from the directories of the sources, because the host of upstream's archives (`graphscope.oss-cn-beijing.aliyuncs.com`) does not answer. What the originals hold beyond those directories could not be compared; the loader names 4 files of one and 8 of the other, and every test that loads them passes. [Evidence](neug.md#neug-python-tests)
- **The Python module on 25.11.** Not offered: 25.11 has protobuf 5.29.5 and the module requires exactly 5.29.6 (the build stops with `Missing dependencies: protobuf==5.29.6`). The Python suite was run on unstable and 26.05 only. [Get it](neug.md#get-it)
- **Other platforms.** Built and checked on x86_64-linux with glibc only. The flake offers aarch64-linux (`platforms = lib.platforms.linux`); nothing was built there. Any other system is untried. [Get it](neug.md#get-it)
- **Other interpreters.** The Python module and the Node.js addon were checked in the `python3` and the `nodejs` of each nixpkgs only. Other versions are untried (`python3Packages.callPackage ./pkgs/neug/python.nix { }` builds the module for another Python). [Use it](neug.md#python)

### Left out on purpose, worth revisiting
- **The service mode runs on cpp-httplib, not on brpc as upstream's Linux build does.** brpc crashed whenever a program loaded `libneug.so` with `dlopen`. Going back needs a brpc release with apache/brpc#3713, which no release has. The C++ tests that link brpc (`test_http_server`, `test_db_svc`, `runtime_wait_test`) are not built; the Python suite and `test_array_service` check the service instead. [Evidence](neug.md#evidence-the-service-mode-crashed-under-dlopen)
- **`INSTALL` does not work, by design.** The extensions are in the store and `INSTALL` deletes the installed file when it cannot match it to upstream's repository, which a path in the store forbids. 12 tests in 2 files of the Python suite are left out (`test_extension_install_load.py`, `test_extension_functions.py`). [Things to know](neug.md#things-to-know)
- **One case of `test_connection` (C++).** `ConnectionReadOnlyTest.ConcurrentProcessesOpenDatabaseSimultaneously` forks two processes that open one database and fails on the UUID defect above. [Left out](neug.md#left-out-on-purpose)
- **`HTTPIntegrationTest` (C++).** It fetches from the network; its own switch skips it. [Left out](neug.md#left-out-on-purpose)
- **The leak tests of the C++ suite run at reduced sizes.** The sizes of upstream's weekly job, because at their own defaults `test_node_create` ran 42110 s (11.7 hours). [Left out](neug.md#left-out-on-purpose)
- **Remote Parquet and `ogbn_mag_small` (Python, 8 tests).** Reads over http, https, oss and s3, and the dataset download; they need the network. [Left out](neug.md#left-out-on-purpose)
- **The LSQB graph (Python).** Upstream's workflow bulk-loads it from a checkout of `github.com/GraphScope/gstest` (`neug/lsqb-sf01`) with a tool that the package does not build. [Left out](neug.md#left-out-on-purpose)
- **The Java driver (Python suite).** `test_java_driver.py` runs `mvn test`; Maven and its network are not in the sandbox, and upstream runs it only with `enable-java-test`. [Left out](neug.md#left-out-on-purpose)
- **The C++ test binary of the Parquet export (Python suite, 12 errors).** The package builds no test binary (`BUILD_TEST=OFF`). [Left out](neug.md#left-out-on-purpose)
- **The extension `test_out_of_tree` (Python suite, 3 tests).** Upstream builds it for its tests only, through `build_extension_lib`. [Left out](neug.md#left-out-on-purpose)
- **The 64 skips of the Python suite.** 29 for the LDBC data and 10 for `comprehensive_graph` (both bulk-loaded by upstream's workflow with a tool that is not built), 6 for credentials of OSS, and upstream's marked skips with their issues. [Left out](neug.md#left-out-on-purpose)
- **6 of the 89 tests of the Node.js addon skip themselves.** Each with its reason in the test file (open issues, features not yet there). [Evidence](neug.md#neug-nodejs-tests)

### Follow-up work
- **Fix two stale counts in comments of the bindings.** `bindings/rust/neug/neug-sys/src/lib.rs` (line 2) says "about thirty functions" and `neug_c.h` has 32; `bindings/neug-c/neug_c.h` (line 24) says NeuG has "about 130" `CHECK` sites, while a `grep` finds about 160 (see [Not built or not tried](#neug)). Editing those files changes the source of `neug-c`, so it waits for the next change to the bindings. [Page](neug.md#things-to-know)

## zvec

### Known defects, not fixed
- **Upstream issue #875 is not worked around.** FastPFOR is compiled with `-msse4.1`, which is not portable. [Page](zvec.md#things-to-know)
- **Upstream issue #781 is not worked around.** `group_by_query` returns nothing after a FLAT index with `use_id_map=false` is opened again. [Page](zvec.md#things-to-know)
- **`GetDocCount()` is twice the number of vectors added.** It is so for flat and HNSW indexes of the `zvec` static libraries, also with the header repair. The searches show nothing is stored twice, so `zvec-library` prints the count and does not assert it. Why it is twice was not looked into. [Evidence](zvec.md#zvec-library)
- **`diskann_mobile_compat_test` fails on its first run now and then, and the cause is not known.** It is not the compiler, and whether the library, the test or the file system is at fault was not found out. `zvec-c-core-tests` runs it again, three times at most, when it is the only test to fail. [Evidence](zvec.md#a-test-that-fails-on-its-first-run)
- **`doc_example` verifies nothing.** Its query filters on `'string_field_0'` where its documents hold `test_string_N`, so it returns nothing and the loop that checks its results checks nothing. This is a bug of the upstream example, recorded and not asserted by `zvec-c-examples`. [Evidence](zvec.md#zvec-c-examples)
- **`.gitmodules` of zvec v0.8.1 has a stale entry.** It names `thirdparty/aio/libaio-0.3`, which the tree does not link. `scripts/update-zvec-c.sh` notes it and checks that every submodule the tree does link was fetched. [Evidence](zvec.md#how-zvec-c-is-built)

### Not built or not tried (unknown)
- **No real kernel without io_uring was run.** The system call is made to fail with a seccomp filter, so a program sees the error of the call and nothing else of such a kernel. [Evidence](zvec.md#without-io_uring)
- **The speed of the library without io_uring is not measured.** `pread` is synchronous, and the library says that "performance may be degraded". [Evidence](zvec.md#the-c-library)
- **`Collection` being `Send` and `Sync` was not tested.** The crate claims it with an `unsafe impl`; the header of the C API says nothing about thread safety, and neither the example nor the tests of the crates (read for it) start a thread of their own. [Page](zvec.md#things-to-know)
- **The crates are tested against zvec v0.8.1 though they were made for v0.8.0-beta2.** The header differs by additions only; their own tests and `zvec-rust-abi` show that what they bind works, not that nothing changed in what the functions do. [Page](zvec.md#things-to-know)
- **The skip lists of the unit tests assume an x86_64 CPU with AVX-512 and VNNI and an unprivileged user.** Some tests skip for want of an instruction set (AVX-512, VNNI, FP16) or because the user can write to a file meant to be read-only. On another CPU or user the check names the difference; none was tried. [Evidence](zvec.md#zvec-c-core-tests)
- **Other platforms are not built: only x86_64-linux with glibc.** On arm and riscv FastPFOR fetches simde while it is configured, which a sandbox cannot do. [Page](zvec.md#get-it)

### Left out on purpose, worth revisiting
- **The `zvec` static libraries stay at NeuG's commit** (`fea2481`, 2026-07-20), not at the latest zvec: the extension is compiled against exactly its headers. They move when NeuG's pin does. [Page](zvec.md#pins-and-update-scripts)
- **libaio is not provided and is not on the `RUNPATH` of `zvec-c`.** On a kernel without io_uring the library reads with `pread` unless libaio is on the library path. Putting libaio on the `RUNPATH` is an open package decision: it changes the package, and every check with it. [Evidence](zvec.md#without-io_uring)
- **The 59 tests of the database layer (`tests/db`) are not run for the `zvec` package.** They are of code that is not part of that package (they need Arrow 21, RocksDB and protobuf). `zvec-c-db-tests` runs the database layer for `zvec-c`. [Why](zvec.md#other-tests-and-programs-not-run)
- **20 tests skip themselves in every mode:** 4 disabled upstream (`GTEST_SKIP()` first in the test) and 16 for NEON kernels, which need AArch64 and never run on x86_64. [List](zvec.md#the-tests-that-skip-themselves)
- **27 Python tests retain upstream skips:** 12 recall variants marked as a known bug and 15 opt-in embedding/reranker integrations requiring models or external services. The other 1,869 pass on unstable. [Checks](zvec.md#python-checks)
- **`perf_bench_test` runs at a reduced scale** (5000 documents and one iteration, not 100000 and 30), with `ZVEC_RUN_PERF_BENCH=1`, because it skips its 17 cases otherwise. [Evidence](zvec.md#zvec-c-db-tests)
- **No control for `zvec-params` and `zvec-c-params` on a GCC before 15 or on clang.** They do not lose the value, so the headers as upstream has them cannot be shown to fail. [Evidence](zvec.md#zvec-params)
- **The helper members `zvec-build` (published as `zvec-rust-build`) and `zvec-rpath-smoke` of the crates' workspace, and the criterion benchmarks, are not run.** This repository does not provide the helpers, and the benchmarks measure and do not test. [Why](zvec.md#other-tests-and-programs-not-run)

### Follow-up work
- **Build the test suites once and run them per mode.** `zvec-c-tests`, `zvec-c-core-tests`, `zvec-c-db-tests` and `zvec-rust-tests` run their three or four passes (the machine's own I/O, `libaio`, `pread`) inside one derivation, about 10 to 11 minutes of tests for each pass of the unit tests. [Checks](zvec.md#checks)
- **Split the outputs of `zvec-c` and `zvec` into `out` and `dev`.** Both put the library, the header and the pkg-config file or static libraries in one output. [What is in it](zvec.md#what-is-in-it)
- **De-duplicate the update scripts** (`scripts/update-zvec.sh`, `update-zvec-c.sh`, `update-zvec-rust.sh`, and the other engines'): peeling an annotated tag to its commit is written out in `update-zvec-c.sh`, `update-zvec-rust.sh`, `update-neug.sh` and `update-duckdb.sh`, and `update-zvec.sh` and `update-zvec-c.sh` both run `nix-prefetch-git` and convert its hash. [Pins](zvec.md#pins-and-update-scripts)
