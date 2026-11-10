# What must work with the libraries: a program links them the way NeuG's vector_search
# extension does and uses an index for real. Linked as an ordinary library, which leaves out
# the components that register themselves, the same program must fail.
{ pkgs }:

let
  inherit (pkgs) lib zvec;

  # GCC 15 and later lose the value of a parameter of a small type in the headers as zvec
  # has them (pkgs/zvec/cube-storage.patch); the compilers before and clang do not
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
in
{
  # A parameter of a small type reads back as what was set, optimized. With the headers as zvec
  # has them, where the compiler is one that loses the value, the same program must fail.
  params = pkgs.runCommandCC "zvec-params-check" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    # <headers> <type> <value>: the program of that type, built and run
    try() {
      c++ -std=c++17 -O3 -DNDEBUG -I"$1" -DPARAM_TYPE="$2" -DPARAM_VALUE="$3" \
        -o "params-$2" ${./params_check.cc} && "./params-$2"
    }

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (type: value: "try ${zvec}/include ${type} ${value}") small
    )}
    ${lib.optionalString loses ''
      # the control: the headers of zvec as they are upstream, with the type of the unit tests
      if try ${zvec.src}/src/include uint32_t 20 >unrepaired.out 2>&1; then
        echo "the headers without the repair worked, so this check shows nothing of it" >&2
        exit 1
      fi
      cat unrepaired.out
      grep -q '^FAIL: set 20, read 0' unrepaired.out
    ''}
    touch $out
  '';

  library = pkgs.runCommandCC "zvec-library-check" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    flags="-std=c++17 -O1 -DNDEBUG -I${zvec}/include ${./zvec_check.cc}"
    libs="${zvec}/lib/libzvec_core.a ${zvec}/lib/libzvec_turbo.a ${zvec}/lib/libzvec_ailego.a"
    system="${zvec}/lib/libroaring.a -pthread -ldl -lrt"

    # whole: the components register themselves in static initializers that nothing refers to
    c++ $flags -o check -Wl,--whole-archive $libs -Wl,--no-whole-archive $system
    ./check

    # as an ordinary library: the program builds and must not work
    c++ $flags -o plain $libs $system
    if ./plain >plain.out 2>&1; then
      echo "the program worked without --whole-archive, so this check shows nothing of it" >&2
      exit 1
    fi
    cat plain.out
    # and for that reason: the registry of the components that register themselves is empty
    grep -q HasMetric plain.out

    touch $out
  '';

  # The unit tests of zvec itself, upstream's own, for the libraries this package builds:
  # ailego (60 tests), core (34) and turbo (1). The same source, patches and flags as the
  # package, with the test targets built and run by ctest. The 59 tests of the database layer
  # (tests/db) are of code that is not part of this package: they link the library zvec, which
  # needs Arrow 21 (built from source with downloaded dependencies), RocksDB and protobuf. The
  # extension of NeuG does not use that layer either. Nothing else is left out.
  tests = zvec.overrideAttrs (old: {
    pname = "zvec-tests";
    doCheck = true;

    # the targets are the test programs, named like their files; the default build phase stays,
    # since the generator (Ninja) is only chosen for it
    ninjaFlags = [ ];

    # the googletest of zvec (1.10.0) uses uintptr_t without including <cstdint>, which GCC 15 and
    # later no longer let pass
    postPatch = old.postPatch + ''
      substituteInPlace thirdparty/googletest/googletest-1.10.0/googletest/src/gtest-death-test.cc \
        --replace-fail '# include <limits.h>' '# include <limits.h>
      # include <cstdint>'
    '';
    preBuild = ''
      ninjaFlagsArray+=( $(find ../tests/ailego ../tests/core ../tests/turbo -name '*_test.cc' -printf '%f\n' \
        | sed 's/\.cc$//' | sort -u) )
    '';

    checkPhase = ''
      runHook preCheck
      export LD_LIBRARY_PATH=$PWD/lib
      # every directory is run before the check fails, to see all that fails
      status=0
      for d in ailego core turbo; do
        echo "=== $d: $(ctest --test-dir tests/$d -N | grep -c 'Test *#') tests"
        ctest --test-dir tests/$d -j"$NIX_BUILD_CORES" --timeout 1500 --output-on-failure --no-tests=error || status=1
      done
      [ $status = 0 ]
      runHook postCheck
    '';

    installPhase = "touch $out";
  });
}
