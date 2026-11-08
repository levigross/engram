# zvec, an in-process vector database, for Nix

[zvec](https://github.com/alibaba/zvec) (Apache-2.0) describes itself as "a lightweight,
lightning-fast, in-process vector database". Here it is packaged as the libraries that the
`vector_search` extension of [NeuG](neug.md) is built on, and for anyone who wants them.

| | |
|---|---|
| `zvec` | the static libraries `libzvec_core.a`, `libzvec_turbo.a`, `libzvec_ailego.a` and `libroaring.a`, and their headers (`include/zvec/{core,ailego,turbo}` and CRoaring's `roaring.h`, `roaring.hh`, `roaring64map.hh`) |

```sh
nix build github:levigross/engram#zvec
```

There are also `stable-zvec` and `previous-zvec` (26.05 and 25.11), built and tested as well,
and `lib.zvec pkgs` for your own flake. It builds in about a minute on unstable.

**It is not the latest zvec.** The commit is the one that the release of NeuG in this
repository has as its submodule (2026-07-20), because the extension is compiled against
exactly its headers; `scripts/update-zvec.sh` takes it from NeuG's pin, and the NeuG build
fails if the headers it carries differ from this package's. zvec itself is at v0.8.1. What a
newer zvec has, such as its Python module, is not built here.

## How it is built

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

## Using the libraries

The components of zvec (metrics, storage, index builders) register themselves in static
initializers that nothing refers to. **Link the three zvec libraries with
`-Wl,--whole-archive`**, as NeuG's extension does; linked as ordinary libraries, the
registry is empty and every attempt to make an index fails.

```sh
c++ -std=c++17 -DNDEBUG -I$zvec/include prog.cc -o prog \
  -Wl,--whole-archive $zvec/lib/libzvec_core.a $zvec/lib/libzvec_turbo.a $zvec/lib/libzvec_ailego.a \
  -Wl,--no-whole-archive $zvec/lib/libroaring.a -pthread -ldl -lrt
```

## Checks

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
of NeuG does not use that layer. The googletest of zvec (1.10.0) lacks an include of `<cstdint>`
that GCC 15 and later need, so the check adds it to its copy.

## Not done

- A newer zvec than NeuG's, and its Python and C bindings.
- Any system but x86_64-linux with glibc.
