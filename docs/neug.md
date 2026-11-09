# NeuG, an embedded graph database, for Nix

[NeuG](https://github.com/alibaba/neug) (Apache-2.0, from the GraphScope team at Alibaba) is a
graph database that runs inside your process and is queried in Cypher. Upstream has Python and
Node.js packages and a C++ library with no C API; this repository builds version 0.3.0 of it
from source with all six of its extensions, and adds a C interface and Rust crates over it that
upstream does not have ([Rust](#rust)).

| Package | What it contains |
|---|---|
| `neug` | `libneug.so`, its headers, the CMake package, and the six extensions |
| `neug-nodejs` | the addon for Node.js (`neug.nodejs`, the second output of `neug`) |
| `python3-neug` | the Python module for the `python3` of nixpkgs, compiled against the installed `neug` |
| `neug-c` | `libneug_c.so` and `neug_c.h`, a C interface over the C++ classes, which the Rust crates link |
| `zvec` | the libraries behind the `vector_search` extension, a [package of its own](zvec.md) |

Contents: [Get it](#get-it) · [Use it](#use-it) · [Things to know](#things-to-know) ·
[What is in it](#what-is-in-it) · [For maintainers and auditors](#for-maintainers-and-auditors) ·
[Open items](#open-items)

## Get it

```sh
nix build github:levigross/engram#neug
nix build github:levigross/engram#neug-nodejs
nix build github:levigross/engram#python3-neug
nix build github:levigross/engram#neug-c
```

`lib.neug pkgs` is the package of your own `pkgs`. At 0.3.0 it builds in about 9 minutes with 12
cores given to it (another build was running at the time).

- **Other nixpkgs.** Packages and [checks](packaging.md#glossary) are offered for three
  nixpkgs: unstable under the names above, and `stable-` (26.05) and `previous-` (25.11) as
  prefixes, for example `stable-neug`. The library, the addon for Node.js, the C interface, the
  Rust consumer, the coexistence check, the C++ test suite, the test suite of the addon and
  `zvec` with its unit tests are built and checked on all three.
- **Python module.** Built and checked on unstable and 26.05, and **not offered on 25.11**. The
  module requires exactly `protobuf` 5.29.6, for the Python package and for the C++ library it
  bundles; that is the `python3Packages.protobuf5` of unstable. 25.11 has 5.29.5, so the build
  stops with `Missing dependencies: protobuf==5.29.6`, and the module would not import there
  without `NEUG_SKIP_PROTOBUF_CHECK=1`. The requirement is read from upstream's
  `pyproject.toml` into `pin.json` (a [pin](packaging.md#glossary)) by `scripts/update-neug.sh`,
  and the flake compares it with the `protobuf5` of each nixpkgs.
- **Platforms.** Built and checked on x86_64-linux with glibc only. The flake also offers it on
  aarch64-linux (`platforms = lib.platforms.linux`), where nothing was built.

## Use it

Every example can `LOAD` any of the six extensions by name, with no `INSTALL` and no download:
see [What is in it](#what-is-in-it).

### C++

```cmake
find_package(neug REQUIRED)
add_executable(app app.cc)
target_include_directories(app PRIVATE ${NEUG_INCLUDE_DIRS})
target_link_libraries(app PRIVATE ${NEUG_LIBRARIES})
```

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

- Use `buildInputs = [ neug ];`. The CMake package finds ZLIB, OpenSSL, abseil and protobuf, so
  the first two are propagated and the others are in the package.
- The CMake package also defines `NEUG_WITH_MIMALLOC`, `ENABLE_CHRONO_YMD` and `NDEBUG` for
  you. The headers branch on them, and a program without them disagrees with the library about
  the layout of its types (upstream exports none of the three).

### Python

```python
from neug import Database

db = Database("", mode="w")            # in memory; a directory for a database on disk
conn = db.connect()
conn.execute("LOAD parquet")           # no INSTALL, no download
conn.execute("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));")
rows = list(conn.execute("MATCH (n:person) RETURN n.id, n.name;"))
```

- `python3-neug` is the package for the `python3` of the nixpkgs the flake pins. Put it in an
  environment with `python3.withPackages (_: [ python3-neug ])`.
- For another Python, or your own `pkgs`, use
  `python3Packages.callPackage ./pkgs/neug/python.nix { }` (it needs the `neug` of that `pkgs`).
- Not offered on 25.11, see [Get it](#get-it). `INSTALL` does not work, see
  [Things to know](#things-to-know).

### Node.js

With `NODE_PATH` set to `lib/node_modules` of the `nodejs` output of `neug` (`neug-nodejs`):

```js
const { Database } = require('neug');
const db = new Database({ databasePath: '', mode: 'w' });
const conn = db.connect();
conn.execute('LOAD parquet');
const rows = [...conn.execute('MATCH (n:person) RETURN n.id, n.name;')];  // an INT64 is a BigInt
```

### C interface

`neug-c` (`bindings/neug-c` in this repository) is a C interface that upstream does not have:
32 functions over `NeugDB`, `Connection` and `QueryResult` (`neug_c.h`). It gives a database in
memory or on disk, one connection, queries with parameters given as JSON, explicit
transactions, and a result read with a cursor and typed getters. The headers of NeuG are made of
protobuf, abseil, glog and rapidjson; a program that includes `neug_c.h` needs none of them.

```c
#include <stdio.h>
#include "neug_c.h"

neug_open_options options;
neug_open_options_init(&options);            /* no path: a database in memory */
neug_db* db = NULL;  neug_conn* conn = NULL;  neug_result* result = NULL;  neug_error* err = NULL;

neug_db_open(&options, &db, &err);
neug_conn_open(db, &conn, &err);
if (neug_conn_query(conn, "MATCH (n:person) RETURN n.name;", NEUG_ACCESS_INFER, NULL,
                    &result, &err) != NEUG_OK) {      /* NEUG_OK is 0; err is set otherwise */
  fprintf(stderr, "%s\n", neug_error_message(err));
}
while (neug_result_step(result)) {           /* 1 while the cursor is on a row */
  const char* text;  size_t length;
  neug_result_get_string(result, 0, &text, &length, &err);   /* not NUL-terminated */
  printf("%.*s\n", (int)length, text);
}
neug_result_free(result);  neug_conn_free(conn);  neug_db_close(db, &err);  neug_db_free(db);
```

- Compile with `-I<neug-c>/include -L<neug-c>/lib -lneug_c`, as the check does (`<neug-c>` is
  the store path of the package); it installs a `neug_c.pc` for `pkg-config` too.
- C++ exceptions never cross the interface. A wrong query comes back as a status with NeuG's
  own code (5001) and its message. A second connection to a database that is read and written,
  or an extension that is not there, is an exception inside the engine and arrives as
  `NEUG_E_EXCEPTION` (10006) with the engine's text, which ends with its code
  (`Error Code: 4001`). The C++ class has no accessor for that code, and the code is not parsed
  out of a message.
- A failed `CHECK` or `LOG(FATAL)` inside the engine ends the process: see
  [Things to know](#things-to-know).

### Rust

The crates are in `bindings/rust/neug`: `neug-sys`, the declarations of `neug_c.h` written by
hand (32 functions of opaque handles and scalars), and `neug`, the safe layer. They are **this
repository's own**, in-process: the engine runs inside your program, with no server and no other
process. (The crates of that name on crates.io are one person's, and run NeuG as a separate
process.) A `Database` is shared, `Connection`s keep it open, `Transaction`s roll back when
dropped, results are read row by row with a cursor that lends the row, a NULL is an `Option`,
and an `Error` carries NeuG's code and words. A connection and a result may move to another
thread.

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

- `neug-sys` builds nothing and downloads nothing: its build script links `libneug_c.so`, found
  by `NEUG_LIB_DIR`, and refuses a header of another version of the interface
  (`NEUG_INCLUDE_DIR`). With Nix, set them to `lib` and `include` of `neug-c`.
- The crates have no dependency outside the repository, so there is nothing to vendor.
  `examples/neug-rust-consumer` is a program that uses them.
- `nix/neug/rust.nix` builds that program with a choice of `tls`, as the other Rust programs of
  this repository: `"none"` (what the crates need, which the lock file must show),
  `"rustls"` or `"openssl"`. Nothing in the crates uses TLS, so the choice only asserts and adds
  what a later feature would need. `libneug.so` itself links OpenSSL (its `httpfs` and its
  service mode), so OpenSSL is in the closure of the program (everything it depends on)
  whichever is chosen.

### Using NeuG and chDB in one program

Both engines of this repository can be in one process: chDB (through its C API, see
[chDB](chdb.md)) and NeuG (through `neug-c`). The check `neug-coexist` runs queries of one
between queries of the other, loads each extension of NeuG between two queries of chDB, starts
either engine first, and runs a thread in each. It looks at every symbol binding the dynamic
linker makes (`LD_DEBUG=bindings`) and finds none of one engine bound to the other
([counts](#neug-coexist)). `libneug.so` defines no symbol in the namespaces of protobuf or
abseil (its version script hides them), and exports no brpc, bthread or gflags symbol. It does
export symbols that mention yaml-cpp, antlr4 and utf8proc; see
[Things to know](#things-to-know).

## Things to know

- **`INSTALL` does not work; `LOAD` does.** The extensions are in the store, and `LOAD <name>`
  finds all six. `INSTALL` asks upstream's repository whether the installed file is the same as
  its own, and when it is not (or there is no network) it deletes the file and downloads
  another, which a path in the store forbids
  (`Cannot delete existing extension file ... Permission denied`).
- **Do not `fork` a process that will open a database.** A process forked from one that has
  already drawn a UUID draws the same UUIDs (`neug::UUIDGenerator` keeps a `thread_local`
  Mersenne twister, seeded once; the check [`neug-fork-uuid`](#neug-fork-uuid) shows it). NeuG
  names the runtime directory of an open database after that UUID, so two read-only processes
  forked from one that opened a database can share a runtime directory, and the first to close
  removes it from under the other
  (`Failed to reserve runtime file ... No such file or directory`). Start a child that opens a
  database with `spawn` or `forkserver` (the default of `multiprocessing` since Python 3.14),
  not `fork`.
- **The engine can stop the process.** A failed `CHECK` or `LOG(FATAL)` inside NeuG ends the
  program; no exception or status comes back. The header of `neug_c.h` names two queries that
  reach one: a `shortestPath` over several labels and a `MERGE` of an unknown label. A program
  that cannot afford that runs the engine in a process of its own. There are over a hundred such
  sites: the header says about 130 (it does not say what it counted), and a `grep` of the source
  at 0.3.0 finds about 160 in 43 files.
- **A database that is read and written allows one connection.** A second one is refused with
  an exception (in C, `NEUG_E_EXCEPTION`; see [C interface](#c-interface)).
- **The service mode runs on cpp-httplib, not on brpc.** `db.serve()` in Python starts an HTTP
  server (the service mode), and `Session` talks to it. Upstream's Linux build serves with brpc,
  which crashed in a Python process; this build uses the transport that upstream builds on
  Windows, and upstream tests that one with a manual load client only. Evidence:
  [the crash](#evidence-the-service-mode-crashed-under-dlopen) and
  [the differences from brpc](#evidence-what-cpp-httplib-did-differently-from-brpc).
- **What queries give back** (found by using all of NeuG from C). A property that a node was
  made without is not NULL but the default of its type (0, 0.0, false). A NULL is what an
  `OPTIONAL MATCH` that finds nothing gives. A column of a result is named with the number of its
  variable in front (`_7_c.name`). The cursor of a result starts on the first row, so the idiom
  is to read the row and then step.
- **Libraries inside `libneug.so`.** It exports symbols that mention yaml-cpp, antlr4 and
  utf8proc. A program with its own copy of one of those, loaded first, would meet them. That
  was not tried, and neither was a program with a protobuf of its own beside `libneug_c.so`.
- **`httpfs` loads; reading over the network was not tried** (the sandbox has none).

## What is in it

- **Six extensions:** `parquet`, `pattern_matching`, `gds`, `httpfs`, `fts` and `vector_search`
  (built on [zvec](zvec.md)). NeuG has no way to link them in: each is a shared library,
  `lib/extension/<name>/lib<name>.neug_extension`, that `LOAD <name>` opens
  ([loadable](packaging.md#glossary), not linked). Upstream gets them with `INSTALL`, from a
  bucket on Alibaba's cloud.
- **Where `LOAD` looks.** The directory is built into `libneug.so` as the prefix of the
  package, so `LOAD` finds the extensions with no `INSTALL`, no download and no environment. The
  environment variable `NEUG_EXTENSION_HOME_PYENV` still overrides it. The Python package sets
  it on import to `lib` of the Nix package `neug` (a value set before the import wins).
- **Outputs.** `neug` has two: `out` (the library, headers, CMake package and extensions in
  `lib/extension`) and `nodejs` (the addon, `lib/node_modules/neug`).
- **Source.** NeuG v0.3.0 (commit `78e6aa42907428b0b50fde2c0d107f6d8acb2bfa`), fetched with
  every submodule, nested ones too. `pkgs/neug/pin.json` holds the hashes and
  `scripts/update-neug.sh` computes them. Nothing is fetched at build time.

## For maintainers and auditors

You do not need this part to use the packages. It says what differs from upstream and why, what
the checks prove, and what they leave out.

### How it is built

NeuG wants a git checkout and an ordinary Linux, and the sandbox has neither. What differs from
upstream's build:

- **Patches of the submodules.** The build applies four of them (abseil-cpp, protobuf, gflags,
  leveldb) with `git apply`, which does nothing outside a checkout; the sources here have every
  submodule and no `.git`. `postPatch` applies them with `patch`. The helper that NeuG uses
  for its other patches falls back to `patch`.
- **yaml-cpp and GCC 15.** yaml-cpp uses `uint16_t` without including `<cstdint>`, which GCC 15
  no longer lets pass. A `sed` adds the include.
- **The extension directory.** The directory `LOAD` looks in is the output directory of the
  build, which is gone once installed. The CMake variable `NEUG_EXTENSION_HOME` sets it
  instead, and the package gives it its own `lib`.
- **The CMake package.** It exports the definitions of rapidjson only; `neug-config.in.cmake`
  is patched to add `NEUG_WITH_MIMALLOC`, `ENABLE_CHRONO_YMD` and `NDEBUG`.
- **The service mode serves over cpp-httplib** (`src/server/httplib_transport.cc`), a second
  transport that upstream builds on Windows only. It runs a request on a plain thread, so
  nothing resumes elsewhere. Both transports define `CreateDefaultServiceTransport` and the
  build picks the file list, so the package takes cpp-httplib (`NEUG_HTTPLIB_TRANSPORT`) and
  builds no brpc. The cost: the three C++ tests of the brpc transport (`test_http_server`,
  `test_db_svc`, `runtime_wait_test`) link brpc and are not built (see
  [Left out on purpose](#left-out-on-purpose)). Two differences from brpc that a client meets
  are patched (`pkgs/neug/httplib-transport.patch`), see
  [the evidence](#evidence-what-cpp-httplib-did-differently-from-brpc).
- **carquet without LTO.** carquet, which `parquet` links, compiles its C with `-flto=auto`.
  The objects are then in the compiler's intermediate form, and the plain `ar` of Nix makes no
  index of such objects: the linker took nothing from the archive and the extension would not
  load (`undefined symbol: carquet_reader_close`). Debian's `ar` loads the plugin by itself,
  which is why upstream does not see it. LTO is turned off for carquet.
- **The addon for Node.js** is a target of the same build as the library, so it is an output of
  `neug`. It asks `node` for the headers of `node-addon-api`, which npm would fetch; the version
  its lock file names (7.1.1) is pinned, with the hash the lock records.
- **`vector_search`** is compiled against the headers of zvec in NeuG's tree and linked with the
  libraries of the package [zvec](zvec.md).
- **`neug-c`** is built against the installed `neug` through its CMake package, as any program
  is. The protobuf, abseil and glog that the headers of NeuG need are linked in as static
  archives, and a version script exports the functions of `neug_c.h` and nothing else.

#### The Python module

Upstream builds the module inside the build of NeuG, which here is 1900 steps at 0.3.0. This
package compiles the five files of `tools/python_bind/src` against the installed `neug` through
its CMake package, one build for each Python, and installs the module as the wheel of upstream
does:

```
site-packages/neug/                          the package, pure Python
site-packages/neug_py_bind.cpython-3XX-*.so  the module it imports, at the root of site-packages
```

- The wheel carries a copy of `libneug.so` next to the module; here the module is linked to the
  `libneug.so` of the package `neug` (its [`RUNPATH`](packaging.md#glossary)), so there is one
  library.
- `LOAD <name>` finds the extensions where `neug/__init__.py` tells the library to look.
  Upstream's default is the directory of the wheel; here it is patched to `lib` of the package
  `neug`, where the six extensions are.
- `PyConnection` deleted its move constructor, which pybind11 3.1 (the one of nixpkgs; upstream
  vendors 3.0.0.dev1) needs of what a method returns by value. It is defaulted: the members
  are a reference and a `shared_ptr`.
- `neug/__init__.py` requires exactly `protobuf` 5.29.6 ([Get it](#get-it) has the consequence
  for 25.11).

#### Evidence: the service mode crashed under `dlopen`

In upstream's Linux build, `Database.serve()` runs a server on brpc, whose requests run on
bthreads (brpc's own user-level threads). A bthread that suspends resumes on another thread. The
compiler may keep the address of a thread-local variable (TLS), or with the TLS descriptors that
GCC 16 makes by default (`-mtls-dialect=gnu2`) its offset, in a register across the suspension.
A program that links `libneug.so` has it in static TLS, where the offset is the same on every
thread, and nothing shows. A library loaded later, as Python and Node.js load `libneug.so` with
`dlopen`, has dynamic TLS, where it is not the same. So the service mode crashed whenever a
program loaded `libneug.so` with `dlopen`, and the fix was to serve over a different
transport than upstream's Linux build.

The rest of this section is the raw record, from the first build
(`/nix/store/w3cim2971ww1y37swfccsh5b2yg5s3i7-neug-0.3.0`, with 67 `R_X86_64_TLSDESC`
relocations in `libneug.so`). Registers, offsets and counts are what the core dumps showed.

- A script of ten lines, `nix/neug/checks/python-serve-repro.py` (open a database,
  `db.serve(10086, "localhost", False)`, sleep a second, stop it), ended with status 139 each
  time: `Fatal Python error: Segmentation fault` a second after the server started, in the
  thread `brpc_wkr:0-1`, at `bthread::TaskGroup::sched_to + 464`: `movq %fs:(%r9), %r14`, a
  load at an offset held in a register (`SIGSEGV`, `invalid permissions for mapped object`).
  `sched_to` makes its descriptor call (`call *(%rax)`) once, at its top, and keeps the result
  in `%r12`. With `LD_PRELOAD=libneug.so`, that is static TLS, the same script ended with 0.
- `-mtls-dialect=gnu` (`__tls_get_addr` calls, 0 descriptors, 48 `DTPMOD64`) was not enough:
  the server started and answered, and `stop_serving()` aborted with
  `task_group.cpp:682] bthread=... sched_to itself!`, then `Fatal Python error: Aborted`
  (status 134), in another run with
  `variable.cpp:197] Check failed: false 'rpc_server_10086_neug_http_service_post_cypher_query_latency_9999' must exist`.
- brpc guards two of its variables (`tls_task_group`, `tls_unique_user_ptr`) against this with
  accessor functions the compiler cannot move across a call, enabled for Clang and for GCC on
  aarch64 only (`butil/thread_local.h`). Enabled for GCC on x86-64 as well, the crash moved: 3 of
  5 runs of the script ended with 139, in `bthread::TaskGroup::task_runner`
  (`libneug.so + 0x212de9e` in the three core dumps), a load through the offset of
  `bvar::detail::AgentGroup<...>::_s_tls_blocks` that was kept in `%r13` across the call of the
  user's function, with the address of `tls_bls` in `%r12`. The two variables brpc guards are
  two of the 67 descriptors, and the crash was in the next: guarding them one by one has no end
  that was shown.
- brpc's own fix (apache/brpc#3713, 33 files) is in no release and does not apply to the 1.12.1
  that NeuG vendors.

#### Evidence: what cpp-httplib did differently from brpc

The suite of the Python module starts the service in 15 of its files. Against cpp-httplib it
found two differences from brpc that a client meets, both patched in
`pkgs/neug/httplib-transport.patch`:

- **`TCP_NODELAY`.** On a connection that is kept, a request took 25 ms and not 0.4 ms, because
  the vendored httplib leaves `TCP_NODELAY` off and the client's delayed ACK holds the second
  segment of the answer. The 20 ms transaction of `test_tp_transaction` expired before it was
  rolled back, and the 7000 inserts of `test_insert_string_column_exaustion` took 211 s, against
  36 s with brpc and 25 s after the patch.
- **A path with two slashes.** A path that starts with two slashes, which is what a client given
  `http://host:port/` asks, was a 404, where brpc routes it like the path without one.

`neug-python-serve` asks for both ([below](#neug-python-serve)).

### Checks

Counts are those of v0.3.0. A [negative control](packaging.md#glossary) is something that must
fail, so that the check cannot pass by accident; the entries below name them. What the suites
leave out is under [Left out on purpose](#left-out-on-purpose).

| Check | What it proves |
|---|---|
| `neug-library` | A program built through the installed CMake package loads the six extensions and runs queries |
| `neug-cpp-tests` | Upstream's C++ test suite passes on the package's source, patches and flags |
| `neug-fork-uuid` | Processes forked after a UUID was drawn draw the same UUID |
| `neug-python` | The module runs in the `python3` of nixpkgs and loads the six extensions |
| `neug-python-serve` | `db.serve()` answers HTTP queries and the process ends cleanly |
| `neug-python-tests` | Upstream's Python test suite passes on the installed module |
| `neug-nodejs` | The addon runs in the `node` of nixpkgs and loads the six extensions |
| `neug-nodejs-tests` | Upstream's test suite of the addon passes |
| `neug-c-smoke` | A C program uses all of `neug_c.h`; the library exports only that interface |
| `neug-rust-consumer` | The Rust example on the crates and `neug-c` runs the same paths |
| `neug-coexist` | chDB and NeuG run in one process with no symbol bound across the engines |

#### `neug-library`

A program is built through the installed CMake package, loads each of the six extensions by name,
and runs a two-hop query and a wrong one. `LOAD` must fail when the extension directory is
pointed at an empty one.

#### `neug-cpp-tests`

The C++ test suite of NeuG, upstream's own, on the source, patches and flags of the package with
`BUILD_TEST` on: 41 test programs, 1361 cases listed by `ctest`, run as upstream's workflows do,
one entry per program. It passes, in about 8 minutes of tests. The tests it leaves out or changes
are under [Left out on purpose](#left-out-on-purpose).

#### `neug-fork-uuid`

A program forks two processes from one that has drawn a UUID with `neug::UUIDGenerator`, and
each child draws one: the two UUIDs are the same. With a parent that has not drawn, they differ
(the control: the sameness comes from the inherited state of the generator, a `thread_local`
Mersenne twister seeded once). This is the reason for the one case left out of `test_connection`.
The check fails when the library stops doing it, which is when to put the case back. The defect
is still in upstream's main (`src/utils/uuid.cc`, 2026-11-06).

#### `neug-python`

The module runs in the `python3` of nixpkgs: an in-memory database, the six extensions loaded by
name from the prefix of the library, the two-hop query, a wrong query that raises. The same
script in a Python without the module must fail, and `LOAD` must fail when
`NEUG_EXTENSION_HOME_PYENV` names an empty directory.

#### `neug-python-serve`

The service mode: `db.serve()` on a free port, a query asked with plain HTTP requests and its
answer compared, `stop_serving()`, and the process must end with status 0 under a time limit (a
crash or a hang fails). The script that crashed the first build (`python-serve-repro.py`) is run
too. The check also asks what the transport must do like brpc: `//cypher` and
`//service_status` answer 200, `GET //transactions` 405, and 200 requests on one connection take
under 2.5 s (0.07 s here; 5.49 s with the transport before the fix). A client against a port
where nothing listens must fail.

#### `neug-python-tests`

The test suite of the module, upstream's own (`pytest tests`, and the Elle tester of
transactions that upstream's workflow runs by name: `tests/transaction/elle_tester_insert.py`,
after Elle, a checker of transaction histories), on the installed module in the sandbox: 1548
passed, 64 skipped, 3 xfailed and 11 deselected, in 7 to 9 minutes (the same counts on 26.05).

- The tests look for the datasets and the Parquet fixtures from their own path (`parents[3]`),
  so they run in a copy of the layout of the repository.
- The same runner without the module must fail, with `No module named 'neug'`.
- No test of the suite forks a process that opens a database: the two that start processes
  (`test_db_concurrent.py`) give them a `Session`, which is an HTTP client.
- The two datasets the loader downloads (`modern_graph`, `tinysnb`) are archives made here from
  the directories of the sources, because the host of upstream's
  (`graphscope.oss-cn-beijing.aliyuncs.com`) does not answer. They are not upstream's archives,
  and what the originals hold beyond those directories could not be compared. The loader names
  4 files of one and 8 of the other and the directories have them, and every test that loads
  them passes. The check fails if anything else is put in the dataset directory.

#### `neug-nodejs`

The addon runs in the `node` of nixpkgs: an in-memory database, the six extensions, the two-hop
query, a wrong query that throws. Without the package on the path of `node`, `require('neug')`
must fail.

#### `neug-nodejs-tests`

The test suite of the addon, upstream's own (`npm test`): 5 files, 89 tests, of which 83 pass
and 6 are skipped by the tests themselves, each with its reason in the test file (open issues,
features not yet there). The data two files open is prepared with upstream's helper, in the build
directory instead of `/tmp`. The same runner without the package on the path must fail.

#### `neug-c-smoke`

A C program that includes only `neug_c.h` and uses all of the interface: a graph and a two-hop
question, every type, parameters, a transaction rolled back and one committed, the six
extensions, and the paths that fail (a wrong query, a getter of the wrong type, a column out of
range, a cursor past the end, parameters that are not an object, an extension that does not
exist, a second connection to a database that is read and written). It also asserts that
`libneug_c.so` (99 KB) exports the functions of the interface and nothing else and needs no
protobuf, abseil or glog symbol. Three things must fail: the program without its path to
`libneug_c.so`, one compiled with a header of another version of the interface, and (by the
assertions) a library that exports or needs more.

#### `neug-rust-consumer`

`examples/neug-rust-consumer`, built on the crates against `neug-c` and run: a graph and a
two-hop question, every kind of cell, parameters, the six extensions loaded by name, a
transaction rolled back, one dropped and one committed, a second connection (refused), a wrong
query, and the connection moved to another thread. The tests of the crates (a unit test of the
JSON of parameters, and the example in the documentation, compiled) run in the same build. The
same binary with its path to the library taken out must not start. The lock file must show no
crate of TLS.

#### `neug-coexist`

chDB and NeuG in one process (see
[Using NeuG and chDB in one program](#using-neug-and-chdb-in-one-program)). The check also
compares what `libneug.so`, `libneug_c.so` and `libchdb.so` export and need, with `nm`: no name
is defined by two of them. The counts at 0.3.0:

- 67601 bindings per run, and no symbol of one engine is bound to the other.
- `libneug.so` exports symbols that mention yaml-cpp (819 of 34455), antlr4 (2514) and utf8proc
  (41). These counts are of the build that serves over cpp-httplib; the build before it exported
  brpc, bthread and gflags symbols as well.

A library preloaded with a `chdb_version` of its own is the control: the check of the bindings
must see it, and does.

### Left out on purpose

What the upstream suites do not run here, each with its reason. The error text of each is in
the check that runs the suite (`nix/neug/checks/default.nix`, `nix/neug/checks/python-tests.nix`)
and in its log.

**In `neug-cpp-tests`:**

- `runtime_wait_test`, `test_http_server` and `test_db_svc`: they include brpc and bthread,
  which the package does not build ([How it is built](#how-it-is-built)). The service is covered
  by `test_array_service` and, from the outside, by `neug-python-serve` and the 15 files of the
  Python suite that start it.
- `HTTPIntegrationTest`: it fetches from the network, and its own switch skips it.
- One case of `test_connection` (`ConnectionReadOnlyTest.ConcurrentProcessesOpenDatabaseSimultaneously`):
  it forks two processes that open one database at the same time, and fails because they draw
  the same UUID (see [`neug-fork-uuid`](#neug-fork-uuid)). The other 31 cases run and are
  counted.
- Two entries named `TEST`: the word `WSHORTEST(` in a query string, taken for a macro of
  googletest by CMake. The cases beside them run in `gopt_test`; the check asserts there are two.
- Changed, not left out: `test_array_service` sends `"parameters":null` where the parser accepts
  only an object (in upstream's main too), so it sends `{}` here.
- Sized: the two leak tests run at the sizes of upstream's scheduled job, because at their own
  defaults `test_node_create` ran 42110 s (11.7 hours) and passed.

**In `neug-python-tests`:**

- `INSTALL`: 12 tests in 2 files, because the extensions are in the store and the repository is
  out of reach (see [Things to know](#things-to-know)).
- Reads of remote Parquet over http, https, oss and s3, and the dataset `ogbn_mag_small`: 8
  tests, which need the network.
- The LSQB graph, which upstream's workflow bulk-loads with a tool that is not built.
- The Java driver, which needs Maven.
- The C++ test binary of the Parquet export: 12 errors, because the package builds no test
  binary.
- The extension `test_out_of_tree`: 3 tests. Upstream builds it for its tests only.
- The 64 skips are the tests' own: 29 for the LDBC data and 10 for `comprehensive_graph` (both
  bulk-loaded by upstream's workflow with a tool that is not built), 6 for credentials of OSS,
  and upstream's marked skips with their issues.

**In `neug-nodejs-tests`:** nothing is left out; 6 tests skip themselves (see above).

## Open items

See [TODO](TODO.md#neug).
