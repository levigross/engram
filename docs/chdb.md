# chDB, ClickHouse in your process, for Nix

[chDB](https://github.com/chdb-io/chdb-core) is the ClickHouse engine as a library: a C
API (`chdb.h`), a Python module, and bindings for other languages. ClickHouse documents it
as its in-process engine, and its own repository has no embedded-library target (its
`programs/` has only `local`, a program).

This repository packages the upstream's **prebuilt** binaries. Building ClickHouse is a
job of its own (chdb-core is a fork of about a gigabyte of source; by its build script it
needs clang 21 and a nightly Rust, and it has 156 submodules) and is not done here.

| | version | what |
|---|---|---|
| `chdb` | chdb-core 26.9.0 | `libchdb.so` (554 MB), `chdb.h`, `chdb.hpp` (which [does not link](#c)), a pkg-config file |
| `python3-chdb` | chdb 4.4.0 on chdb-core 26.9.0 | the Python module, with the engine inside |

```sh
nix build github:levigross/engram#chdb
nix build github:levigross/engram#python3-chdb
```

with the prefixes `stable-` (26.05) and `previous-` (25.11) for the other nixpkgs. From a
flake of yours, `inputs.<this>.lib.chdb pkgs` is the package of your `pkgs`, and
`(lib.chdb pkgs).pythonModule pkgs.python3Packages` the Python module.

## Where the binaries come from

`libchdb.so` is the release asset `linux-x86_64-libchdb.tar.gz` of
`chdb-io/chdb-core` v26.9.0, and the Python module is two wheels from the same release
and from `chdb-io/chdb` v4.4.0. They are **not signed or attested** by anyone. What
`scripts/update-chdb.sh` does is download each file, compute its hash itself, and fail
unless the release's own `SHA256SUMS` (for the `chdb` wheel, the digest GitHub shows for
the asset) says the same. That is all it proves: the file is the one the release lists.
The hashes are in `pkgs/chdb/pin.json`. The x86_64-linux and aarch64-linux assets are
pinned; only x86_64-linux has been built, and macOS is not offered.

The library links to nothing but the C library (it carries the rest inside; the symbol
versions it uses are no newer than glibc 2.4) and has a `RUNPATH` into the upstream's build
directory, which the package removes. At run time it reads a store of certificate
authorities and the time zone database from the file system, [below](#what-the-engine-reads-at-run-time).
The Python module does not use this library: its wheel carries an engine of its own, from
the same release.

The two wheels both ship `chdb/__init__.py`. pip installs `chdb-core` first and `chdb`
over it, and the Python module here unpacks them in that order.

## C

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

The engine starts once per process and one process has one data path: closing the last
connection stops it, and the header says why a host should not do that before it is done
with chDB. `chdb_version()` is the version of chdb-core (`26.9.0`); the engine itself
logs the ClickHouse version it is built from (26.9.2.1).

In the Nix sandbox the engine prints a warning with a stack trace that it cannot find the
cgroup files. It is harmless, except that a test of the noise on stderr takes it for noise
(see the checks).

**The C++ header does not work with this release.** `chdb.hpp` declares and calls
`CHDB::connect_chdb_with_exception`, and `libchdb.so` has no such symbol: of that name it
exports only the C function `connect_chdb`. A C++ program that uses the header fails to link
(`undefined reference to CHDB::connect_chdb_with_exception`), and the four C++ examples that
chdb-core ships fail on top of that, because they write `chdb::` where the header's
namespace is `CHDB`. The header is installed as the upstream ships it (it is the one in the
source at the tag); `chdb-core-c-tests` records both failures. From C++, `chdb.h` is the way
in.

### What the engine reads at run time

Two things from the file system, which the sandbox of a Nix build does not have:

- a store of certificate authorities. Without one, an HTTPS request fails with "Cannot load
  default CA certificates". `SSL_CERT_FILE` names it.
- the time zone database. Without it a query that uses the ORC format fails with
  `orc::TimezoneError`: "Time zone file /usr/share/zoneinfo/GMT does not exist. Please install
  IANA time zone database and set TZDIR env". `TZDIR` names it.

The checks set `SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt` and
`TZDIR=${pkgs.tzdata}/share/zoneinfo`. A program run outside the sandbox on a system that has
neither needs the same. The package sets nothing: it is a library, and there is no program
of its own to wrap.

## Python

```python
import chdb
print(chdb.query("SELECT sum(number + 1) FROM numbers(100)", "CSV"))
frame = chdb.query("SELECT number AS n FROM numbers(3)", "DataFrame")
```

pandas and pyarrow are dependencies of the module.

## Rust

The crate is [`chdb-rust`](https://crates.io/crates/chdb-rust) 2.1.0. Its build script
generates the bindings from `chdb.h` and, unless it is told where a library is, downloads
an engine. `examples/chdb-rust-consumer` shows a program that is given ours:

```nix
pkgs.rustPlatform.buildRustPackage {
  # ...
  nativeBuildInputs = [ pkgs.rustPlatform.bindgenHook pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];            # see below
  env = {
    CHDB_LIB_DIR = "${chdb}/lib";            # nothing is downloaded
    CHDB_INCLUDE_DIR = "${chdb}/include";
  };
}
```

**OpenSSL or rustls.** The download in the build script is done with `reqwest`, whose
default TLS is OpenSSL. It never runs when `CHDB_LIB_DIR` is set, but the build script is
compiled, so the build needs OpenSSL and `pkg-config` (without them it stops in
`openssl-sys`). That is the `tls = "openssl"` build of `nix/chdb/rust.nix`. For people
who cannot or do not want OpenSSL there is `tls = "rustls"`: the crate, as the lock file
has it with its checksum, is copied, the TLS feature of its `reqwest` is changed to
rustls, and the program is built with that copy as a `[patch.crates-io]` entry and its
own lock file (`Cargo.rustls.lock`). That lock file has no `openssl-sys`, `native-tls` or
`hyper-tls`, which an assertion at evaluation requires, and the build is given neither
`openssl` nor `pkg-config`. The program that comes out is the same in both: the TLS stack
only mattered to the build. `scripts/update-chdb-rust.sh` makes both lock files.

**TLS at run time.** The crate has a feature of its own that needs TLS when the program
runs: `durable-s3`, which keeps a database ("a durable object") in S3 or a store that
speaks its protocol, with `ureq` and **rustls**. The example exposes it as the feature of
the same name and as a mode (`--s3 <url> write|read`).

The crate says it is for engine v26.11.0-rc.2 and is used here with 26.9.0. The calls the
example makes work, including the durable feature, and the crate's own test suite runs
against our library (`chdb-rust-tests`, below): all of it passes but one case, which asks
for the newer engine.

## Checks

Five for each nixpkgs, named `chdb-<check>` (`stable-chdb-library`, ...). All pass on
unstable, 26.05 and 25.11 on x86_64-linux.

| | |
|---|---|
| `chdb-library` | a C program compiled against the header and linked with `-lchdb`: the library reports the version of the pin, `SELECT sum(...)` is 5050, a Parquet file written by one query is read back by another (499500), a query of a table that does not exist is an error |
| `chdb-python` | the module answers a query, hands a result to pandas, and keeps a table in a session that is opened again; the same script with an interpreter without chdb must fail |
| `chdb-rust-consumer` | the Rust program, built with OpenSSL, runs a query, a Parquet round trip and a wrong query; the same binary with its path to `libchdb` taken out must not start |
| `chdb-rust-consumer-rustls` | the same, built with rustls and no OpenSSL |
| `chdb-rust-consumer-s3` | built with rustls and `durable-s3`: a program writes a table to a durable object in a store (a stand-in for S3, speaking HTTPS with a certificate authority and a certificate it signed) and flushes it; another process, with nothing but the store, reads it back. The same write without the authority in `AWS_CA_BUNDLE` must fail, and the store sees the handshake fail |

The stand-in answers `GET` and `PUT` with `ETag`s and the conditional `If-None-Match: *`
and `If-Match` the protocol uses for its lease; it checks nothing else, and it does not
check signatures. rustls would not accept the self-signed certificate of a certificate
authority as the certificate of the server itself, hence the two certificates.

### Upstream's own tests

Four more checks run the test suites of chDB itself, at the tags this repository pins, against
the packages here. Each asserts its counts, so that tests dropped silently fail the check, and
each has a control that must fail. They were built on unstable; the Python ones for chdb-core are
offered only where nixpkgs has what they import (`adbc-driver-manager`, which 26.05 and 25.11
lack).

| | |
|---|---|
| `chdb-rust-tests` | the test suite of `chdb-rust` 2.1.0 against our `libchdb`, in two passes: the default features (244 tests pass) and `--features durable` (349 pass); 4 upstream benchmarks are `#[ignore]`d in each. One case of `runtime_faces`, `shutdown_after_mergetree_merges`, fails with this engine and says why itself: before v26.11.0-rc.2 `chdb_shutdown` is refused. The check requires exactly that case to fail with that message, so an engine that fixes it makes the check fail until the exception is removed. `durable_s3` needs a bucket and skips itself; the stand-in store of `chdb-rust-consumer-s3` covers what it asks of S3 |
| `chdb-core-c-tests` | the 19 scripts in chdb-core's `examples/`, each compiling a C or C++ program against the header and the library and running it, as upstream does: 18 pass, one test inside them skips itself (a leak test that needs an AddressSanitizer build). The 19th, `runCppExamples`, must fail and does, for the reasons given under [C](#c). A script run against a header of the wrong version must fail |
| `chdb-core-python-tests` | the tests in chdb-core's `tests/` with its own runner (`run_all.py`), against its wheel and our library: 1529 tests, 36 skipped (they need a remote ClickHouse, MinIO, MySQL, MongoDB or an AI provider). Eight fail and the check requires exactly those eight to fail: seven in `test_stdout_noise.py` and one in `test_wasm_udf.py`, which take the engine's message about missing cgroup files for noise on stderr; where the files can be read they pass. Three modules are left out because they read from the Internet: `test_delta_lake.py`, `test_issue60.py` and `test_on_df.py` (which downloads a file when it is imported) |
| `chdb-datastore-tests` | the tests of chdb's Python part (`datastore/tests`, and those of `tests/` that concern the installed module): 11274 pass, 23 skip, 79 are expected failures, and 6 pass although upstream marks them expected to fail (stale markers, not strict). `test_writeback.py` (75 tests) runs against two ClickHouse servers on the loopback, as upstream's CI does, and `test_durable.py` has 50 and the agent tests 52. Left out: `TestRemoteClickHousePushdown` (2 tests), which sends `CREATE OR REPLACE TABLE function remote(...)`, not SQL; `test_agents_smolagents`, as `gradio` does not evaluate in nixpkgs; `tests/clickhouse_connect`, a separate pipeline upstream; the two tests that import duckdb or ibis skip themselves, since neither is installed (with the `duckdb` of this repository's overlay, evaluating `ibis-framework` fails, see [the overlay](duckdb.md#as-an-overlay)) |

The engine needs a store of certificate authorities and the time zone database, which the
sandbox lacks: these checks set `SSL_CERT_FILE` and `TZDIR`
([above](#what-the-engine-reads-at-run-time)).

## Not done

- Building the engine from source, which is what would make it auditable.
- The C++ API (`chdb.hpp`): the release's library does not export what the header calls.
- The engine of the release newer than v26.9.0 that the Rust crate asks for
  (v26.11.0-rc.2 is a pre-release): the pin stays on the release.
- The upstream tests run on unstable only.
- Anything but x86_64-linux with glibc: the aarch64-linux assets are pinned and untried,
  macOS is not offered.
- CPUs without AVX: the upstream's build flags were not read here, and the library was
  only run on machines that have it.
- The other bindings of chDB (Go, Node.js, ...).
