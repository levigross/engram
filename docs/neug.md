# NeuG, an embedded graph database, for Nix

[NeuG](https://github.com/alibaba/neug) (Apache-2.0, from the GraphScope team at Alibaba) is a
graph database that runs inside your process and is queried in Cypher. It has Python and
Node.js packages upstream, and a C++ library with no C API. This repository builds it from
source, version 0.3.0, with every extension it has, and adds a C interface and Rust crates
over it (not upstream's: see [Rust](#rust)).

| | |
|---|---|
| `neug` | `libneug.so`, its headers, the CMake package, and the six extensions |
| `neug-nodejs` | the addon for Node.js (`neug.nodejs`, the second output of `neug`) |
| `python3-neug` | the Python module, for the `python3` of the nixpkgs, compiled against the installed `neug` |
| `neug-c` | `libneug_c.so` and `neug_c.h`, a C interface of 32 functions over the C++ classes, which the Rust crates link |
| `zvec` | the libraries behind the `vector_search` extension, a [package of its own](zvec.md) |

```sh
nix build github:levigross/engram#neug
nix build github:levigross/engram#neug-nodejs
nix build github:levigross/engram#python3-neug
nix build github:levigross/engram#neug-c
```

`lib.neug pkgs` is the package of your own `pkgs`. It builds in about 9 minutes with 12 cores
given to it (another build was running at the time).

Packages and checks are offered for three nixpkgs (`stable-` is 26.05, `previous-` is 25.11),
x86_64-linux with glibc only. Built and checked on all three: the library, the addon for
Node.js, the C interface, the Rust consumer, the coexistence check, the C++ test suite, the
test suite of the addon and `zvec`, with its unit tests. The Python module and its checks are
built on unstable and 26.05, and **not offered on 25.11**, which has protobuf 5.29.5 where the
module requires exactly 5.29.6 (the build stops with `Missing dependencies:
protobuf==5.29.6`; the requirement is read from upstream's `pyproject.toml` into `pin.json`
by `scripts/update-neug.sh`, and the flake compares it with the `protobuf5` of each nixpkgs).

## Extensions

`parquet`, `pattern_matching`, `gds`, `httpfs`, `fts` and `vector_search`. NeuG has no way to
link them in: each is a shared library, `lib/extension/<name>/lib<name>.neug_extension`, that
`LOAD <name>` opens. Upstream gets them with `INSTALL`, from a bucket on Alibaba's cloud. Here
the directory they are looked for in is built into `libneug.so` as the prefix of the package,
so `LOAD` finds them with no `INSTALL`, no download and no environment (the environment
variable `NEUG_EXTENSION_HOME_PYENV` still overrides it).

## C++

```cmake
find_package(neug REQUIRED)
add_executable(app app.cc)
target_include_directories(app PRIVATE ${NEUG_INCLUDE_DIRS})
target_link_libraries(app PRIVATE ${NEUG_LIBRARIES})
```

with `buildInputs = [ neug ];`. The CMake package finds ZLIB, OpenSSL, abseil and protobuf, so
the first two are propagated and the others are in the package. It also defines
`NEUG_WITH_MIMALLOC`, `ENABLE_CHRONO_YMD` and `NDEBUG` for you: the headers branch on them,
and a program without them disagrees with the library about the layout of its types (upstream
exports none of the three).

```cpp
#include <neug/neug.h>

neug::NeugDB db;
db.Open("");                       // in memory
auto conn = db.Connect();
conn->Query("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));");
// Query gives an expected: it is false on error, and .value() is the result
auto result = conn->Query("MATCH (n:person) RETURN n.name;").value();
while (result.hasNext()) {         // the cursor starts on the first row
  std::cout << result.GetString(0) << "\n";
  result.next();
}
```

## Node.js

With `NODE_PATH` set to `lib/node_modules` of the `nodejs` output of `neug` (`neug-nodejs`):

```js
const { Database } = require('neug');
const db = new Database({ databasePath: '', mode: 'w' });
const conn = db.connect();
conn.execute('LOAD parquet');
const rows = [...conn.execute('MATCH (n:person) RETURN n.id, n.name;')];  // an INT64 is a BigInt
```

## C

`neug-c` (`bindings/neug-c` in this repository) is a C interface that upstream does not have:
32 functions over `NeugDB`, `Connection` and `QueryResult` (`neug_c.h`). A database in memory or
on disk, one connection, queries with parameters given as JSON, explicit transactions, and a
result read with a cursor and typed getters. The headers of NeuG are made of protobuf, abseil,
glog and rapidjson; a program that includes `neug_c.h` needs none of them. `libneug_c.so` is
99 KB, exports the functions of the interface and nothing else, and needs no protobuf, abseil
or glog symbol from outside (the check asserts all three).

C++ exceptions never cross it. A wrong query comes back as a status with NeuG's own code
(5001) and its message. A second connection to a database that is read and written, or an
extension that is not there, is an exception inside the engine and arrives as
`NEUG_E_EXCEPTION` (10006) with the engine's text, which ends with its code (`Error Code:
4001`): the C++ class has no accessor for it, and the code is not parsed out of a message.

What it cannot catch: a failed `CHECK` or `LOG(FATAL)` inside the engine ends the process.
There are over a hundred of them (the header counts about 130; a count by `grep` of the source finds about 160 sites in 43 files), and the header names two queries that reach one (a
`shortestPath` over several labels, a `MERGE` of an unknown label). A program that cannot
afford that runs the engine in a process of its own.

Learned about NeuG by using all of it from C: a property that a node was made without is not
NULL but the default of its type (0, 0.0, false); a NULL is what an `OPTIONAL MATCH` that finds
nothing gives; a column of a result is named with the number of its variable in front
(`_7_c.name`); the cursor of a result starts on the first row, so the idiom is to read the
row and then step.

## Rust

The crates are in `bindings/rust/neug`: `neug-sys`, the declarations of `neug_c.h` written by
hand (the interface is thirty functions of opaque handles and scalars), and `neug`, the safe
layer. They are **this repository's own**, in-process: the engine runs inside your program,
with no server and no other process. (The crates of that name on crates.io are one person's,
and run NeuG as a separate process.) A `Database` is shared, `Connection`s keep it open,
`Transaction`s roll back when dropped, results are read row by row with a cursor that lends the
row, a NULL is an `Option`, and an `Error` carries NeuG's code and words. A connection and a
result may move to another thread.

```rust
let db = neug::Database::in_memory()?;
let mut conn = db.connect()?;
conn.query("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));")?;
conn.query("CREATE (:person {id: 1, name: 'Alice'});")?;
let mut result = conn.query("MATCH (n:person) RETURN n.id, n.name;")?;
let mut rows = result.rows();
while let Some(row) = rows.next() {
    println!("{} {}", row.get::<i64>(0)?, row.get::<String>(1)?);
}
```

`neug-sys` builds nothing and downloads nothing: its build script links `libneug_c.so`, found
by `NEUG_LIB_DIR`, and refuses a header of another version of the interface
(`NEUG_INCLUDE_DIR`). With Nix, set them to `lib` and `include` of `neug-c`. The crates have no
dependency outside the repository, so there is nothing to vendor. `examples/neug-rust-consumer`
is a program that uses them, and `nix/neug/rust.nix` builds it with a choice of `tls`, as the
other Rust programs of this repository: `"none"` (what the crates need today, which the lock
file must show), `"rustls"` or `"openssl"`. Nothing in the crates uses TLS, so the choice only
asserts and adds what a later feature would need. `libneug.so` itself links OpenSSL (its
`httpfs` and its service mode), so OpenSSL is in the closure whichever is chosen.

Both engines of this repository can be in one process. `neug-coexist` runs chDB (through its C
API) and NeuG (through `neug-c`) in one program, with queries of one between queries of the
other, each extension of NeuG loaded between two queries of chDB, either engine started first,
and a thread in each. It looks at the dynamic linker's bindings (`LD_DEBUG=bindings`): in 67601
bindings per run no symbol of one engine is bound to the other. `libneug.so` defines no symbol
in the namespaces of protobuf or abseil (its version script hides them). It does export symbols
that mention yaml-cpp (819 of 34455), antlr4 (2514) and utf8proc (41), so a program with its own
copy of one of those, loaded first, would meet them; that, and a program with a protobuf of its
own beside the shim, was not tried. (Those counts are of the build that serves over
cpp-httplib: it exports no brpc, bthread or gflags symbol, which the build before it did.)

## Python

`python3-neug` is the package for the `python3` of the nixpkgs the flake pins; put it in an
environment with `python3.withPackages (_: [ python3-neug ])`. For another Python, or your own
`pkgs`, it is
`python3Packages.callPackage ./pkgs/neug/python.nix { }` (it needs the `neug` of that `pkgs`).

```python
from neug import Database

db = Database("", mode="w")            # in memory; a directory for a database on disk
conn = db.connect()
conn.execute("LOAD parquet")           # no INSTALL, no download
conn.execute("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));")
rows = list(conn.execute("MATCH (n:person) RETURN n.id, n.name;"))
```

It is built apart from the library. Upstream builds the module inside the build of NeuG, which
here is 1900 steps; this package compiles the five files of `tools/python_bind/src` against the
installed `neug` through its CMake package, one build for each Python, and installs the module
as the wheel of upstream does:

```
site-packages/neug/                          the package, pure Python
site-packages/neug_py_bind.cpython-3XX-*.so  the module it imports, at the root of site-packages
```

The wheel carries a copy of `libneug.so` next to the module; here the module is linked to the
`libneug.so` of the package `neug` (its `RUNPATH`), so there is one library.

`LOAD <name>` finds the extensions where `neug/__init__.py` tells the library to look. Upstream's
default is the directory of the wheel; here it is patched to `lib` of the package `neug`, where
the six extensions are. `neug` sets `NEUG_EXTENSION_HOME_PYENV` to it when it is imported, and
a value of that variable set before the import still wins. `INSTALL` does not work, by design:
it asks the repository of upstream whether the installed file is the same as its own, and when
it is not (or there is no network) it deletes the file and downloads another, which a path in
the store forbids (`Cannot delete existing extension file ... Permission denied`).

Besides that default, the build of the module differs from upstream's in one change and one
requirement:

- `PyConnection` deleted its move constructor, which pybind11 3.1 (the one of nixpkgs; upstream
  vendors 3.0.0.dev1) needs of what a method returns by value. It is defaulted: the members
  are a reference and a `shared_ptr`.
- `neug/__init__.py` requires exactly `protobuf` 5.29.6, as the library it bundles, which is
  `python3Packages.protobuf5` of unstable. The nixpkgs 25.11 has 5.29.5, so the module would
  not import there without `NEUG_SKIP_PROTOBUF_CHECK=1`.

`db.serve()` starts the HTTP server of the service mode, and `Session` talks to it. That server
is not the one of upstream's Linux build, see below.

A process that is forked from one that has already drawn a UUID draws the same UUIDs
(`neug::UUIDGenerator` keeps a `thread_local` Mersenne twister, seeded once; the check
`neug-fork-uuid` shows it). NeuG names the runtime directory of an open database after that
UUID, so two read-only processes forked from one that opened a database can share a runtime
directory, and the first to close removes it from under the other (`Failed to reserve runtime
file ... No such file or directory`). A child that opens a database should be started with
`spawn` or `forkserver` (the default of `multiprocessing` since Python 3.14), not `fork`. No
test of the suite forks a process that opens a database: the two that start processes
(`test_db_concurrent.py`) give them a `Session`, which is an HTTP client.

## What the build needed

NeuG wants a git checkout and an ordinary Linux, and the sandbox has neither:

- Four patches of its submodules are applied with `git apply`, which does nothing outside a
  checkout. They are applied in `postPatch`; the helper it uses for the others falls back to
  `patch`.
- yaml-cpp uses `uint16_t` without including `<cstdint>`, which GCC 15 no longer lets pass.
- The service mode crashed whenever a program loaded `libneug.so` with `dlopen`, as Python and
  Node.js do, and the fix is to serve over a different transport than upstream's Linux build.
  `Database.serve()` runs a server on brpc, whose requests run on bthreads: a bthread that
  suspends resumes on another thread, and the compiler may keep the address of a thread-local
  variable, or with the TLS descriptors that GCC 16 makes by default (`-mtls-dialect=gnu2`)
  its offset, in a register across the suspension. A program that links `libneug.so` has it
  in static TLS, where the offset is the same on every thread, and nothing shows; a library
  loaded later has dynamic TLS, where it is not. The evidence, on the first build
  (`/nix/store/w3cim2971ww1y37swfccsh5b2yg5s3i7-neug-0.3.0`, 67 `R_X86_64_TLSDESC`
  relocations in `libneug.so`):
  - A script of ten lines, `nix/neug/checks/python-serve-repro.py` (open a database,
    `db.serve(10086, "localhost", False)`, sleep a second, stop it), ended with status 139 each
    time: `Fatal Python error: Segmentation fault` a second after the server started, in the
    thread `brpc_wkr:0-1`, at `bthread::TaskGroup::sched_to + 464`: `movq %fs:(%r9), %r14`,
    a load at an offset held in a register (`SIGSEGV`, `invalid permissions for mapped
    object`). `sched_to` makes its descriptor call (`call *(%rax)`) once, at its top, and
    keeps the result in `%r12`. With `LD_PRELOAD=libneug.so`, that is static TLS, the same
    script ended with 0.
  - `-mtls-dialect=gnu` (`__tls_get_addr` calls, 0 descriptors, 48 `DTPMOD64`) was not
    enough: the server started and answered, and `stop_serving()` aborted with
    `task_group.cpp:682] bthread=... sched_to itself!`, then `Fatal Python error: Aborted`
    (status 134), in another run with `variable.cpp:197] Check failed: false
    'rpc_server_10086_neug_http_service_post_cypher_query_latency_9999' must exist`.
  - brpc guards two of its variables (`tls_task_group`, `tls_unique_user_ptr`) against this
    with accessor functions the compiler cannot move across a call, enabled for Clang and
    for GCC on aarch64 only (`butil/thread_local.h`). Enabled for GCC on x86-64 as well, the
    crash moved: 3 of 5 runs of the script ended with 139, in `bthread::TaskGroup::task_runner`
    (`libneug.so + 0x212de9e` in the three core dumps), a load through the offset of
    `bvar::detail::AgentGroup<...>::_s_tls_blocks` that was kept in `%r13` across the call of
    the user's function, with the address of `tls_bls` in `%r12`. The two variables brpc
    guards are two of the 67 descriptors, and the crash was in the next: guarding them one by
    one has no end that was shown. brpc's own fix (apache/brpc#3713, 33 files) is in no
    release and does not apply to the 1.12.1 that NeuG vendors.

  NeuG has a second transport, cpp-httplib (`src/server/httplib_transport.cc`), that upstream
  builds on Windows only. It runs a request on a plain thread, so nothing resumes elsewhere.
  Both define `CreateDefaultServiceTransport` and the build picks the file list, so the
  package takes the second (`NEUG_HTTPLIB_TRANSPORT`) and builds no brpc. The cost: upstream
  tests this transport on Windows with a manual load client only, and the three C++ tests of
  the brpc transport (`test_http_server`, `test_db_svc`, `runtime_wait_test`) link brpc and are
  not built. The suite of the
  Python module, which starts the service in 15 of its files, found two differences from
  brpc that a client meets, both patched (`pkgs/neug/httplib-transport.patch`): on a connection
  that is kept, a request took 25 ms and not 0.4, because the vendored httplib leaves
  `TCP_NODELAY` off and the client's delayed ACK holds the second segment of the answer (the
  20 ms transaction of `test_tp_transaction` expired before it was rolled back, and the 7000
  inserts of `test_insert_string_column_exaustion` took 211 s, 36 with brpc and 25 after the
  patch); and a path that starts with two slashes, which is what a client given
  `http://host:port/` asks, was a 404, where brpc routes it like the path without one.
  `neug-python-serve` asks for both.
- carquet, which `parquet` links, compiles its C with `-flto=auto`, and the plain `ar` of Nix
  makes no index of such objects: the linker took nothing from the archive and the extension
  would not load (`undefined symbol: carquet_reader_close`). Debian's `ar` loads the plugin by
  itself, which is why upstream does not see it. LTO is turned off for carquet.
- The directory `LOAD` looks in is the output directory of the build, which is gone once
  installed; `NEUG_EXTENSION_HOME` sets it instead.
- The addon for Node.js asks `node` for the headers of `node-addon-api`, which npm would
  fetch; the version its lock file names is pinned, with the hash the lock records.

## Checks

| | |
|---|---|
| `neug-library` | a program is built through the installed CMake package, loads each of the six extensions by name, runs a two-hop query and a wrong one; `LOAD` must fail when the extension directory is pointed at an empty one |
| `neug-nodejs` | the addon runs in the `node` of nixpkgs: an in-memory database, the six extensions, the two-hop query, a wrong query that throws; without the package on the path of `node`, `require('neug')` must fail |
| `neug-nodejs-tests` | the test suite of the addon, upstream's own (`npm test`): 5 files, 89 tests, of which 83 pass and 6 are skipped by the tests themselves, each with its reason in the test file (open issues, features not yet there). The data two files open is prepared with upstream's helper, in the build directory instead of `/tmp`. The same runner without the package on the path must fail |
| `neug-cpp-tests` | the C++ test suite of NeuG, upstream's own, on the source, patches and flags of the package with `BUILD_TEST` on: 41 test programs, 1361 cases listed by `ctest`, run as upstream's workflows do, one entry per program. It passes, in about 8 minutes of tests. Left out or changed, each with its evidence in the check: `runtime_wait_test`, `test_http_server` and `test_db_svc` (they include brpc and bthread, which the package no longer builds); `HTTPIntegrationTest` (fetches from the network; its own switch skips it); one case of `test_connection`, which forks two processes that open one database at the same time and fails because they draw the same UUID (see `neug-fork-uuid`; the other 31 cases run and are counted); two entries named `TEST`, which are the word `WSHORTEST(` in a query string taken for a macro of googletest by CMake (the cases beside them run in `gopt_test`; the check asserts there are two); `test_array_service` sends `"parameters":null` where the parser accepts only an object, in upstream's main too, so it sends `{}` here. The two leak tests run at the sizes of upstream's scheduled job, because at their own defaults `test_node_create` ran 42110 s (11.7 hours) and passed |
| `neug-fork-uuid` | a program forks two processes from one that has drawn a UUID with `neug::UUIDGenerator`, and each child draws one: the two UUIDs are the same. With a parent that has not drawn, they differ (the control: the sameness comes from the inherited state of the generator, a `thread_local` Mersenne twister seeded once). This is the reason for the one case left out of `test_connection`; the check fails on the day the library no longer does it, which is the time to put the case back. Still in upstream's main (`src/utils/uuid.cc`, 2026-11-06) |
| `neug-c-smoke` | a C program that includes only `neug_c.h` and uses all of the interface: a graph and a two-hop question, every type, parameters, a transaction rolled back and one committed, the six extensions, and the paths that fail (a wrong query, a getter of the wrong type, a column out of range, a cursor past the end, parameters that are not an object, an extension that does not exist, a second connection to a database that is read and written). It also asserts that `libneug_c.so` exports the functions of the interface and nothing else and needs no protobuf, abseil or glog symbol. Three things must fail: the program without its path to `libneug_c.so`, one compiled with a header of another version of the interface, and (by the assertions) a library that exports or needs more |
| `neug-rust-consumer` | `examples/neug-rust-consumer`, built on the crates against `neug-c` and run: a graph and a two-hop question, every kind of cell, parameters, the six extensions loaded by name, a transaction rolled back, one dropped and one committed, a second connection (refused), a wrong query, and the connection moved to another thread. The tests of the crates (a unit test of the JSON of parameters, and the example in the documentation, compiled) run in the same build. The same binary with its path to the library taken out must not start. The lock file must show no crate of TLS |
| `neug-coexist` | chDB and NeuG in one process (see [Rust](#rust)). A library preloaded with a `chdb_version` of its own is the control: the check of the bindings must see it, and does |
| `neug-python` | the module runs in the `python3` of nixpkgs: an in-memory database, the six extensions loaded by name from the prefix of the library, the two-hop query, a wrong query that raises. The same script in a Python without the module must fail, and `LOAD` must fail when `NEUG_EXTENSION_HOME_PYENV` names an empty directory |
| `neug-python-serve` | the service mode: `db.serve()` on a free port, a query asked with plain HTTP requests and its answer compared, `stop_serving()`, and the process must end with status 0 under a time limit (a crash or a hang fails). The script that crashed the first build (`python-serve-repro.py`) is run too. It also asks what the transport must do like brpc: `//cypher` and `//service_status` answer 200, `GET //transactions` 405, and 200 requests on one connection take under 2.5 s (0.07 s here; 5.49 s with the transport before the fix). A client against a port where nothing listens must fail |
| `neug-python-tests` | the test suite of the module, upstream's own (`pytest tests`, and the Elle tester of transactions that upstream's workflow runs by name), on the installed module in the sandbox: 1548 passed, 64 skipped, 3 xfailed and 11 deselected, in 7 to 9 minutes (the same counts on 26.05). The tests look for the datasets and the Parquet fixtures from their own path (`parents[3]`), so they run in a copy of the layout of the repository. The same runner without the module must fail, with `No module named 'neug'`. The two datasets the loader downloads (`modern_graph`, `tinysnb`) are archives made here from the directories of the sources, because the host of upstream's (`graphscope.oss-cn-beijing.aliyuncs.com`) does not answer; they are not upstream's archives and what the originals hold beyond those directories could not be compared. The loader names 4 files of one and 8 of the other and the directories have them, and every test that loads them passes. The check fails if anything else is put in the dataset directory. Left out, each with its error text in `python-tests.nix` and in the log: `INSTALL` (12 tests, 2 files, as the extensions are in the store and the repository is out of reach), reads of remote Parquet over http, https, oss and s3 and the dataset `ogbn_mag_small` (8 tests), the LSQB graph, the Java driver (Maven), the C++ test binary of the Parquet export (12 errors), and the extension `test_out_of_tree`, which upstream builds for its tests (3 tests). The 64 skips are the tests' own: 29 for the LDBC data, 10 for `comprehensive_graph` (both bulk-loaded by upstream's workflow with a tool that is not built), 6 for credentials of OSS, and upstream's marked skips with their issues |

## Not done

- **The service mode runs on cpp-httplib, not on brpc as upstream's Linux build does** (see
  "What the build needed"). Upstream tests that transport on Windows with a manual load client
  only. Its C++ tests of the service (`test_http_server`, `test_db_svc`) and `runtime_wait_test`
  link brpc and are not built; the service is checked through the Python module
  (`neug-python-serve`, and the 15 files of its suite that start it) and through
  `test_array_service`. Going back to brpc needs a release of it with apache/brpc#3713.
- The Python module is not offered on 25.11 (its protobuf is 5.29.5, the module wants 5.29.6).
  The Python suite was run on unstable and 26.05, not on 25.11.
- Left out of the upstream suites, each with its reason in the check that runs them: for Python
  what needs the network (`INSTALL`, `httpfs` reads of remote Parquet, the dataset
  `ogbn_mag_small`), the LSQB graph, the Java driver (Maven), a C++ test binary, and the
  extension `test_out_of_tree`, which upstream builds for its tests only; for C++ what is listed
  in `neug-cpp-tests`. `httpfs` loads; reading over the network was not tried, as the sandbox
  has none.
- The two datasets that the Python tests download are rebuilt from the directories of the
  sources, not upstream's archives, whose host did not answer (see `neug-python-tests`).
- `INSTALL` does not work, as the extensions are in the store (see Python).
- A process forked from one that has drawn a UUID shares the runtime directory of a database
  it opens read-only with its siblings (see Python and `neug-fork-uuid`). A defect of NeuG,
  not repaired here; one case of its C++ suite is left out for it.
- A program with its own copy of yaml-cpp, antlr4 or utf8proc, loaded before `libneug.so`,
  would meet the copies that it exports (see [Rust](#rust)); not tried.
- Any system but x86_64-linux with glibc.
- The engine can stop the process on some input: its source has about 160 `CHECK` and
  `LOG(FATAL)` sites in 43 files (a count by `grep`; none was exercised).
