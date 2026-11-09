# chDB, ClickHouse in your process, for Nix

[chDB](https://github.com/chdb-io/chdb-core) is the ClickHouse engine as a library: a C API
(`chdb.h`), a Python module, and bindings for other languages. It runs inside your program,
with no server; this repository packages the upstream's **prebuilt** binaries, pinned by hash.

| Package | Version | What it is |
|---|---|---|
| `chdb` | chdb-core 26.9.0 | `libchdb.so`, the headers `chdb.h` and `chdb.hpp` ([which does not link](#things-to-know)), a pkg-config file |
| `python3-chdb` | chdb 4.4.0 on chdb-core 26.9.0 | the Python module, with the engine inside |

Contents: [Get it](#get-it) · [Use it](#use-it) · [Things to know](#things-to-know) ·
[What the engine reads at run time](#what-the-engine-reads-at-run-time) ·
[What is in it](#what-is-in-it) · [For maintainers and auditors](#for-maintainers-and-auditors) ·
[Open items](#open-items)

## Get it

```sh
nix build github:levigross/engram#chdb
nix build github:levigross/engram#python3-chdb
```

The prefixes `stable-` (26.05) and `previous-` (25.11) give the same package built with the
[other nixpkgs](packaging.md#glossary), for example `#stable-chdb`. From your own flake
(`engines` is your input of this repository, as in the
[README](../README.md#use-it-from-your-flake)):

```nix
engines.lib.chdb pkgs                                       # libchdb and its headers
(engines.lib.chdb pkgs).pythonModule pkgs.python3Packages   # the Python module
```

Platform: x86_64-linux with glibc is the only one built and checked. The aarch64-linux assets
are pinned and untried; macOS is not offered.

## Use it

### C

```sh
cc prog.c $(pkg-config --cflags --libs chdb) -o prog
```

```c
#include <chdb.h>
#include <stdio.h>

int main(void) {
  char *args[] = {"prog", NULL};
  chdb_connection *conn = chdb_connect(1, args);
  chdb_result *result = chdb_query(*conn, "SELECT sum(number + 1) FROM numbers(100)", "CSV");
  if (chdb_result_error(result)) { fprintf(stderr, "%s\n", chdb_result_error(result)); return 1; }
  fwrite(chdb_result_buffer(result), 1, chdb_result_length(result), stdout);   /* 5050 */
  chdb_destroy_query_result(result);
  chdb_close_conn(conn);
}
```

- The engine starts once per process, and one process has one data path. Closing the last
  connection stops the engine; the header says why a host should not do that before it is done
  with chDB.
- From C++, include `chdb.h`. `chdb.hpp` does not link ([details](#things-to-know)).

### Python

```python
import chdb
print(chdb.query("SELECT sum(number + 1) FROM numbers(100)", "CSV"))
frame = chdb.query("SELECT number AS n FROM numbers(3)", "DataFrame")
```

To put the module in an interpreter of your own:

```nix
pkgs.python3.withPackages (_: [ ((engines.lib.chdb pkgs).pythonModule pkgs.python3Packages) ])
```

- pandas and pyarrow are dependencies of the module.
- The module carries an engine of its own, from the same release. It does not use `libchdb.so`.

### Rust

The crate is [`chdb-rust`](https://crates.io/crates/chdb-rust) 2.1.0. Its build script
generates the bindings from `chdb.h` and, unless it is told where a library is, downloads
an engine. `examples/chdb-rust-consumer` is a program that is given ours:

```nix
pkgs.rustPlatform.buildRustPackage {
  # ...
  nativeBuildInputs = [ pkgs.rustPlatform.bindgenHook pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];            # see TLS, below
  env = {
    CHDB_LIB_DIR = "${chdb}/lib";            # nothing is downloaded
    CHDB_INCLUDE_DIR = "${chdb}/include";
  };
}
```

- The crate is made for engine v26.11.0-rc.2 (a pre-release); here it runs on the pinned
  26.9.0. Everything the example calls works, including the `durable` feature.
- One test case of the crate itself asks for the newer engine: see
  [Left out on purpose](#left-out-on-purpose).

#### TLS: OpenSSL or rustls

At build time, the build script of the crate is compiled with `reqwest`, whose default TLS is
OpenSSL. The download it would do never runs when `CHDB_LIB_DIR` is set, but the build still
needs OpenSSL and `pkg-config`; without them it stops in `openssl-sys`. The snippet above is
that build (`tls = "openssl"` in `nix/chdb/rust.nix`).

If you cannot or do not want OpenSSL, `tls = "rustls"` in the same file builds the program
with neither OpenSSL nor `pkg-config`. [How](#building-the-rust-example-with-rustls) is under
maintainers. The program that comes out is the same in both: the TLS stack only mattered to
the build.

At run time, a program needs TLS only with the crate's `durable-s3` feature. It keeps a
database as one object in S3 (the crate calls it a durable object), or in a store that speaks
the S3 protocol, using `ureq` with rustls. The example exposes it as the feature `durable-s3`
and as a mode: `--s3 <url> write|read`.

## Things to know

- **The C++ header does not link.** `chdb.hpp` declares and calls
  `CHDB::connect_chdb_with_exception`; the library exports the C function `connect_chdb` but
  not that one. A C++ program that uses the header fails to link with
  `undefined reference to CHDB::connect_chdb_with_exception`. The four C++ examples that
  chdb-core ships fail on top of that, because they write `chdb::` where the header's
  namespace is `CHDB`. The header is installed as the upstream ships it (the one in the source
  at the tag). From C++, use `chdb.h`. The check `chdb-core-c-tests` records both failures.
- **HTTPS and the ORC format need files from the file system.** A certificate store and the
  time zone database: [below](#what-the-engine-reads-at-run-time).
- **In the Nix sandbox the engine prints a warning with a stack trace** that it cannot find the
  cgroup files. It is harmless noise.
- **The binaries are not signed or attested.** The hash proves only that a file is the one the
  release lists, and the engine is not built from source here:
  [where they come from](#where-the-binaries-come-from).
- **The library has been run only on CPUs with AVX.**

## What the engine reads at run time

Two things from the file system, which the sandbox of a Nix build does not have:

- a store of certificate authorities. Without one, an HTTPS request fails with "Cannot load
  default CA certificates". `SSL_CERT_FILE` names it.
- the time zone database. Without it a query that uses the ORC format fails with
  `orc::TimezoneError`: "Time zone file /usr/share/zoneinfo/GMT does not exist. Please install
  IANA time zone database and set TZDIR env". `TZDIR` names it.

The checks set `SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt` and
`TZDIR=${pkgs.tzdata}/share/zoneinfo`. A program run outside the sandbox on a system that has
neither needs the same. The package sets neither: it is a library, and there is no program of
its own to wrap.

## What is in it

| Output | Contents |
|---|---|
| `chdb` | `lib/libchdb.so` (554 MB at v26.9.0), `include/chdb.h`, `include/chdb.hpp`, `lib/pkgconfig/chdb.pc` |
| `python3-chdb` | the module `chdb`, from two wheels; the engine is inside; depends on pandas and pyarrow |

- Versions: `chdb_version()` returns the version of chdb-core, `26.9.0`. The engine itself
  logs the ClickHouse version it is built from, 26.9.2.1.
- `libchdb.so` links to nothing but the C library; it carries the rest inside, and the symbol
  versions it uses are no newer than glibc 2.4. It has a [RUNPATH](packaging.md#glossary) into
  the upstream's build directory, which the package removes.

### Where the binaries come from

- `libchdb.so` is the release asset `linux-x86_64-libchdb.tar.gz` of `chdb-io/chdb-core`
  v26.9.0.
- The Python module is two wheels: `chdb-core` (the engine) from the same release, and `chdb`
  (the Python part) from `chdb-io/chdb` v4.4.0.
- Nobody signs or attests them. `scripts/update-chdb.sh` downloads each file, computes its
  hash itself, and fails unless the release's own `SHA256SUMS` (for the `chdb` wheel, the
  digest GitHub shows for the asset) says the same. That proves only that the file is the one
  the release lists. The hashes are in `pkgs/chdb/pin.json`.
- The x86_64-linux and aarch64-linux assets are pinned.
- The two wheels both ship `chdb/__init__.py`. pip installs `chdb-core` first and `chdb` over
  it, and the Python module here unpacks them in that order.

## For maintainers and auditors

You do not need this part to use chDB.

### How it is built

- **Why prebuilt.** ClickHouse documents chDB as its in-process engine, and its own repository
  has no embedded-library target (its `programs/` has only `local`, a program). The engine
  comes from chdb-core, a fork; building it is a job of its own and is not done here
  ([open items](TODO.md#chdb)).
- **`libchdb`.** `libchdb.so`, `chdb.h` and `chdb.hpp` are installed as the release ships them.
  The package runs `patchelf --remove-rpath` on the library, which needs nothing but libc. It
  does not strip the file: it is one file of more than 500 MB that the upstream has already
  stripped.
- **`python3-chdb`.** The two wheels are unpacked in the order above into one directory. The
  extension modules find each other and the library they bundle by `$ORIGIN`, so nothing else
  is patched.

#### Building the Rust example with rustls

This is `tls = "rustls"` in `nix/chdb/rust.nix`:

1. The crate, as the OpenSSL lock file has it with its checksum verified, is copied, and the
   TLS feature of the `reqwest` in its build script is changed to rustls.
2. The program is built with that copy as a `[patch.crates-io]` entry, and with its own lock
   file, `examples/chdb-rust-consumer/Cargo.rustls.lock`.
3. That lock file has no `openssl-sys`, `native-tls` or `hyper-tls`. An assertion at evaluation
   requires that `openssl-sys` is absent, and the build is given neither `openssl` nor
   `pkg-config`, so it could not have used them.
4. `scripts/update-chdb-rust.sh` makes both lock files.

### Checks

Checks are named `chdb-<check>`, with the prefixes `stable-` and `previous-` for the other
nixpkgs (`stable-chdb-library`). Each has a
[negative control](packaging.md#glossary): something that must fail, so that the check cannot
pass by accident.

#### Checks of this repository

Five for each nixpkgs. All pass on unstable, 26.05 and 25.11 on x86_64-linux.

| Check | What it proves |
|---|---|
| `chdb-library` | A C program built against the header and `-lchdb` gets right answers |
| `chdb-python` | The module answers a query, feeds pandas and reopens a session |
| `chdb-rust-consumer` | The Rust program, built with OpenSSL, runs queries against our library |
| `chdb-rust-consumer-rustls` | The same program, built with rustls and no OpenSSL |
| `chdb-rust-consumer-s3` | A durable object written to a stand-in for S3 over TLS is read back |

- `chdb-library`: the library reports the version of the pin, `SELECT sum(...)` is 5050, a
  Parquet file written by one query is read back by another (499500), and a query of a table
  that does not exist is an error.
- `chdb-python`: the same script with an interpreter without chdb must fail.
- `chdb-rust-consumer`: the program runs a query, a Parquet round trip and a wrong query. The
  same binary with its path to `libchdb` taken out must not start.
- `chdb-rust-consumer-rustls`: the same checks as `chdb-rust-consumer`.
- `chdb-rust-consumer-s3`: the program is built with rustls and `durable-s3`. It writes a table
  to a durable object in the store and flushes it; another process, with nothing but the store,
  reads it back. The store is a stand-in for S3 that speaks HTTPS with a certificate authority
  and a certificate that the authority signed (rustls would not accept the self-signed
  certificate of an authority as the certificate of the server itself, hence the two). The same
  write without the authority in `AWS_CA_BUNDLE` must fail, and the store sees the handshake
  fail.

The stand-in answers `GET` and `PUT`, with an `ETag` (a version tag) on each answer. It also
answers the conditional `If-None-Match: *` and `If-Match`, which the protocol uses so that one
writer at a time holds the object (its lease). It requires that a request carries an
`Authorization` header, and checks nothing else: it does not check signatures.

#### Upstream's own tests

Four more checks run the test suites of chDB itself, at the tags this repository pins, against
the packages here. Each asserts its counts, so that tests dropped silently fail the check.
They were built on unstable. Three are offered on every
nixpkgs. `chdb-core-python-tests` is offered on unstable only: it imports
`adbc-driver-manager`, which 26.05 and 25.11 lack (`nix/chdb/checks/tests/default.nix`).

| Check | What it proves |
|---|---|
| `chdb-rust-tests` | The test suite of `chdb-rust` 2.1.0 passes against our `libchdb`, in two passes |
| `chdb-core-c-tests` | The C and C++ example programs of chdb-core build and run against our library |
| `chdb-core-python-tests` | The Python tests of chdb-core pass against its wheel and our library |
| `chdb-datastore-tests` | The tests of chdb's Python part pass against the installed module |

Counts below are for chdb-core v26.9.0 and `chdb-rust` 2.1.0.

- `chdb-rust-tests`: two passes, since the crate has features that change what is compiled. The
  default features: 244 tests pass. With `--features durable`: 349 pass. 4 upstream benchmarks
  are `#[ignore]`d in each pass.
- `chdb-core-c-tests`: the 19 scripts in chdb-core's `examples/`, each compiling a C or C++
  program against the header and the library and running it, as upstream does. 18 pass, and one
  test inside them skips itself. The 19th, `runCppExamples`, must fail and does, for the
  reasons given in [Things to know](#things-to-know). A script run against a header of the
  wrong version must fail.
- `chdb-core-python-tests`: the tests in chdb-core's `tests/`, with its own runner
  (`run_all.py`). 1529 tests run and 36 are skipped. Eight fail, and the check requires
  exactly those eight to fail.
- `chdb-datastore-tests`: the tests of chdb's Python part (`datastore/tests`, and those of
  `tests/` that concern the installed module). 11274 pass, 23 skip, and 79 are expected
  failures. Another 6 pass although upstream marks them expected to fail; the markers are
  stale, and not strict. `test_writeback.py` (75 tests) runs against two ClickHouse servers on
  the loopback, as upstream's CI does. `test_durable.py` has 50 tests and the agent tests 52.

The checks set `SSL_CERT_FILE` and `TZDIR`, as
[above](#what-the-engine-reads-at-run-time).

### Left out on purpose

#### Not run

| What | In check | Why |
|---|---|---|
| 4 upstream benchmarks | `chdb-rust-tests` | Upstream marks them `#[ignore]` ("run with --release --ignored") |
| `durable_s3` | `chdb-rust-tests` | Needs a bucket and skips itself; `chdb-rust-consumer-s3` covers what it asks of S3 |
| A leak test | `chdb-core-c-tests` | Needs an AddressSanitizer build; skips itself |
| 36 tests | `chdb-core-python-tests` | Need a remote ClickHouse, MinIO, MySQL, MongoDB or an AI provider |
| `test_delta_lake.py`, `test_issue60.py`, `test_on_df.py` | `chdb-core-python-tests` | Read from the Internet; `test_on_df.py` downloads a file when imported |
| `TestRemoteClickHousePushdown` (2 tests) | `chdb-datastore-tests` | Sends `CREATE OR REPLACE TABLE function remote(...)`, which is not SQL |
| `test_agents_smolagents` | `chdb-datastore-tests` | `gradio` does not evaluate in nixpkgs |
| `tests/clickhouse_connect` | `chdb-datastore-tests` | A separate pipeline upstream |
| 2 tests that import duckdb or ibis | `chdb-datastore-tests` | Skip themselves: neither is installed |

With the `duckdb` of this repository's overlay, evaluating `ibis-framework` fails, which is
why ibis is not installed: see [the overlay](duckdb.md#as-an-overlay).

#### Fail by design

Each check requires exactly these failures, so an engine or a header that fixes one makes the
check fail until the exception is removed.

| What | In check | Why |
|---|---|---|
| `shutdown_after_mergetree_merges`, a case of `runtime_faces` | `chdb-rust-tests` | Before engine v26.11.0-rc.2, `chdb_shutdown` is refused; the test says so itself |
| `runCppExamples` | `chdb-core-c-tests` | The header does not link and the examples use the wrong namespace |
| 8 tests: 7 in `test_stdout_noise.py`, 1 in `test_wasm_udf.py` | `chdb-core-python-tests` | They take the cgroup warning for noise on stderr; where the files can be read they pass |

## Open items

See [TODO](TODO.md#chdb).
