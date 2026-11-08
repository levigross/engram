# The check of ../checks for the other package of zvec, against the headers of this version: a
# parameter of a small type reads back as what was set, optimized. With the headers as zvec has
# them, where the compiler is one that loses the value, the same program must fail.
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
in
pkgs.runCommandCC "zvec-c-params-check" { } ''
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
''
