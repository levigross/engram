# What must work with zvec's C API library (pkgs/zvec-c): what the library is made of and
# exports, the repair of the headers, and zvec's own tests and examples of the C API.
{ pkgs }:

let
  inherit (pkgs) lib zvec-c;

  # GCC 15 and later lose the value of a parameter of a small type in the headers as zvec
  # has them (pkgs/zvec-c/cube-storage.patch); the compilers before and clang do not
  loses = pkgs.stdenv.cc.isGNU && lib.versionAtLeast pkgs.stdenv.cc.version "15";

  # the types of a parameter that fit in a pointer, and a value of each
  small = {
    bool = "true";
    int8_t = "-7";
    uint8_t = "200";
    int16_t = "-1234";
    uint16_t = "54321";
    int32_t = "-123456";
    uint32_t = "20";
    int64_t = "-1234567890123LL";
    uint64_t = "1234567890123ULL";
    float = "2.5f";
    double = "0.125";
  };

  # What the library may need: the C library, and nothing else. (glibc has had libdl, librt and
  # libpthread inside libc since 2.34, and keeps the names for programs that ask for them.)
  allowedNeeded = [
    "ld-linux-x86-64\\.so\\.2"
    "libc\\.so\\.6"
    "libdl\\.so\\.2"
    "libm\\.so\\.6"
    "libpthread\\.so\\.0"
    "librt\\.so\\.1"
  ];
in
{
  # The check of ../checks for the other package of zvec, against the headers of this version:
  # a parameter of a small type reads back as what was set, optimized. With the headers as zvec
  # has them, where the compiler is one that loses the value, the same program must fail.
  params = pkgs.runCommandCC "zvec-c-params-check" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    # the headers with the repair that the package applies to its source
    mkdir -p repaired/src
    cp -r --no-preserve=mode ${zvec-c.src}/src/include repaired/src/include
    patch -p1 -d repaired -i ${zvec-c.cubePatch}

    # <headers> <type> <value>: the program of that type, built and run
    try() {
      c++ -std=c++17 -O3 -DNDEBUG -I"$1" -DPARAM_TYPE="$2" -DPARAM_VALUE="$3" \
        -o "params-$2" ${../checks/params_check.cc} && "./params-$2"
    }

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (type: value: "try repaired/src/include ${type} ${value}") small
    )}
    ${lib.optionalString loses ''
      # the control: the headers of zvec as they are upstream, with the type of the unit tests
      if try ${zvec-c.src}/src/include uint32_t 20 >unrepaired.out 2>&1; then
        echo "the headers without the repair worked, so this check shows nothing of it" >&2
        exit 1
      fi
      cat unrepaired.out
      grep -q '^FAIL: set 20, read 0' unrepaired.out
    ''}
    touch $out
  '';

  # What the library is made of and what it exports: only its C interface, all of it, in a
  # shared object that needs nothing but the C library of the system.
  library =
    pkgs.runCommandCC "zvec-c-library-check"
      {
        nativeBuildInputs = [
          pkgs.patchelf
          pkgs.pkg-config
        ];
      }
      ''
        export HOME=$TMPDIR
        cd $TMPDIR
        lib=${zvec-c}/lib/libzvec_c_api.so

        # the files of the package
        (cd ${zvec-c} && find . -type f | sort) > files
        printf '%s\n' ./include/zvec/c_api.h ./lib/libzvec_c_api.so ./lib/pkgconfig/zvec_c_api.pc | sort > files.expected
        diff files.expected files

        # it needs the C library and nothing else. Its C++ runtime is inside it, so a program that
        # links it needs no libstdc++, and cannot bring one that disagrees. (<file>)
        needed_ok() {
          readelf -d "$1" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' | sort > "needed-$(basename "$1")"
          cat "needed-$(basename "$1")"
          ! grep -vxE '${lib.concatStringsSep "|" allowedNeeded}' "needed-$(basename "$1")"
        }
        needed_ok $lib || { echo "the library needs more than the C library" >&2; exit 1; }
        # the control: a library that needs the C++ runtime
        cp $lib extra.so
        chmod +w extra.so
        patchelf --add-needed libstdc++.so.6 extra.so
        if needed_ok extra.so >/dev/null 2>&1; then
          echo "a library that needs libstdc++ was accepted" >&2
          exit 1
        fi

        # the functions of the header, those of zvec's own list of exports, and those the shared
        # object defines are the same set
        header_names() { tr '\n' ' ' < "$1" | grep -oE 'ZVEC_CALL +zvec_[a-z0-9_]+' | sed -E 's/^ZVEC_CALL +//' | sort -u; }
        header_names ${zvec-c}/include/zvec/c_api.h > header
        sed -n '/global:/,/local:/p' ${zvec-c.src}/src/binding/c/exported_symbols.lds \
          | grep -oE 'zvec_[a-z0-9_]+' | sort -u > script
        nm -D --defined-only $lib | awk '{ print $3 }' | sort -u > defined
        echo "the header declares $(wc -l < header) functions, zvec's list exports $(wc -l < script), the library defines $(wc -l < defined) symbols"
        [ -s header ]
        cmp header script
        cmp header defined
        # the control: a header with one declaration less is not the same set
        grep -v '^zvec_collection_flush$' header > header.fewer
        if cmp -s header.fewer defined; then
          echo "a header with a declaration less was accepted" >&2
          exit 1
        fi
        # and the header is the one of the source
        cmp ${zvec-c}/include/zvec/c_api.h ${zvec-c.src}/src/include/zvec/c_api.h

        # what the library says it is
        cc -Wall -Wextra -Werror -I${zvec-c}/include -o version_check ${./version_check.c} \
          -L${zvec-c}/lib -lzvec_c_api
        ./version_check v${zvec-c.version}
        # the control: another version expected
        if ./version_check v${zvec-c.version}.1 >/dev/null 2>&1 || ./version_check v0.0.1 2>/dev/null; then
          echo "a version that is not the library's was accepted" >&2
          exit 1
        fi

        # a program that is linked to it finds it by its RUNPATH
        readelf -d version_check | grep -F RUNPATH | grep -F '${zvec-c}/lib'
        cp version_check stripped
        chmod +w stripped
        patchelf --remove-rpath stripped
        if ./stripped v${zvec-c.version} 2>stripped.err; then
          echo "the program ran without its RUNPATH" >&2
          exit 1
        fi
        cat stripped.err
        grep -q 'libzvec_c_api.so' stripped.err

        # pkg-config says how to use it
        PKG_CONFIG_PATH=${zvec-c}/lib/pkgconfig pkg-config --exists --exact-version=${zvec-c.version} zvec_c_api
        # shellcheck disable=SC2046
        cc -Wall -Wextra -Werror -o version_check_pc ${./version_check.c} \
          $(PKG_CONFIG_PATH=${zvec-c}/lib/pkgconfig pkg-config --cflags --libs zvec_c_api)
        ./version_check_pc v${zvec-c.version}
        # the control: without the package in the path there is nothing to find
        if pkg-config --exists zvec_c_api; then
          echo "pkg-config found zvec_c_api without the package" >&2
          exit 1
        fi

        touch $out
      '';

  # The unit tests of zvec itself, upstream's own, of the libraries that need no Arrow: ailego,
  # core and turbo
  core-tests = import ./suite.nix {
    inherit pkgs;
    name = "core";
    # libaio, which the library loads with dlopen and the package does not provide, is on the
    # path of the tests, so that the tests of that code run (DiskAnnLibAioDeathTest skips itself
    # where dlopen finds none, tests/core/algorithm/diskann/diskann_libaio_lifetime_test.cc:82)
    libraryPath = [ pkgs.libaio ];
    # The tests that skip themselves, each for a reason in its source:
    #  - disabled by upstream, with GTEST_SKIP() as the first statement:
    #    ThreadQueue.MultiThreadWithHighPriority (tests/ailego/parallel/thread_queue_test.cc:113,
    #    "TODO(windows): add it back") and TestMaxIndexSize of the flat, HNSW and sparse HNSW
    #    streamers (flat_streamer_test.cc:1520, hnsw_streamer_test.cc:1694,
    #    hnsw_sparse_streamer_test.cc:1210);
    #  - the tests of the NEON kernels of turbo, for AArch64, which this machine is not (the
    #    messages in tests/turbo/turbo_{neon_batch,neon_distance,fp16_quantizer,fp32_quantizer,
    #    pq_fast_quantizer,pq_int4_quantizer,pq_int8_quantizer}_test.cc are "requires AArch64"
    #    and "lacks NEON").
    skipped = [
      "ThreadQueue.MultiThreadWithHighPriority"
      "FlatStreamerTest.TestMaxIndexSize"
      "HnswStreamerTest.TestMaxIndexSize"
      "HnswSparseStreamerTest.TestMaxIndexSize"
      "Fp16Quantizer.AutoDispatchSelectsNeonFp16"
      "Fp16Quantizer.NeonBatchMatchesSingleAcrossBoundaries"
      "Fp16Quantizer.NeonCosineRetainsFp16Arithmetic"
      "Fp16Quantizer.NeonDistanceMatchesScalar"
      "Fp16Quantizer.NeonDistancesPreserveFp32Range"
      "Fp32Quantizer.NeonDistanceMatchesScalar"
      "NeonBatch.AutoDispatchIncludesRawUniformAndSdc"
      "NeonDistance.DispatchProvidesAllKernels"
      "NeonDistance.Fp16AccumulatesInFp32"
      "NeonDistance.Fp16MatchesScalarForRemainders"
      "NeonDistance.Fp32MatchesScalarForRemainders"
      "NeonDistance.RecordIntegerProductsMatchScalarForRemainders"
      "PqFastScanKernel.NeonMatchesScalar"
      "PqInt4SimdConsistency.NeonMatchesScalar"
      "PqInt8SimdConsistency.NeonMatchesScalar"
    ];
    # The test of the file reader for Windows (tests/core/algorithm/diskann/CMakeLists.txt, in
    # the branch for WIN32 and filtered out of the sources everywhere else) is the one test file
    # there is that is not a test here.
    notRegistered = [ "diskann_file_reader_windows_test" ];
    dirs = [
      "ailego"
      "core"
      "turbo"
    ];
    control = {
      file = "tests/ailego/utility/bit_string_helper_test.cc";
      from = "EXPECT_EQ(data_read, m);";
      to = "EXPECT_EQ(data_read, m + 1);";
      target = "bit_string_helper_test";
      dir = "ailego";
    };
  };

  # The unit tests of the database layer (tests/db), the code that the C API is
  db-tests = import ./suite.nix {
    inherit pkgs;
    name = "db";
    # perf_bench_test (tests/db/sqlengine/perf_bench_test.cc) skips its 17 cases unless
    # ZVEC_RUN_PERF_BENCH=1, "to keep CI fast"; they run real queries and some check what they
    # get (ExpectedHitCounts), so they run here, on 5000 documents and one iteration instead of
    # 100000 and 30, and nothing skips itself.
    env = {
      ZVEC_RUN_PERF_BENCH = "1";
      ZVEC_PERF_DOC_COUNT = "5000";
      ZVEC_PERF_ITERATIONS = "1";
    };
    # The test of the Windows code pages (tests/db/utf8_acp/CMakeLists.txt returns at once
    # unless the system is Windows with MSVC, and there makes one program for each code page).
    notRegistered = [ "utf8_acp_test" ];
    dirs = [ "db" ];
    extraTargets = [
      "data_generator"
      "collection_optimizer"
    ];
    serial = "recovery";
    control = {
      file = "tests/db/common/cgroup_util_test.cc";
      from = "EXPECT_EQ(1, cpu_cores);";
      to = "EXPECT_EQ(7, cpu_cores);";
      target = "cgroup_util_test";
      dir = "db";
    };
  };

  # zvec's own test of the C API (tests/c), compiled against the installed library
  tests = import ./tests.nix { inherit pkgs; };

  # zvec's own examples of the C API (examples/c), compiled against the installed library, run
  examples = import ./examples.nix { inherit pkgs; };
}
