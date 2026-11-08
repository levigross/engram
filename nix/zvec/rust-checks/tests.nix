# The tests of the crates zvec-rust-sys and zvec-rust, the zvec team's own, run against our
# library (pkgs/zvec-c): the repository of the crates at the tag the crates of crates.io were
# made from, with the lock file it ships (scripts/update-zvec-rust.sh keeps a copy, since a
# build cannot read one from a fetched source, and the check fails if the repository's differs).
#
# What runs is what the team's own CI runs (`cargo test --lib`, `--tests`, `--doc`) for the
# two crates that this repository provides. The workspace has two more members, which are not
# provided: zvec-build (published as zvec-rust-build, a helper for the build script of a
# program that wants the library staged next to it) and zvec-rpath-smoke (a program that tests
# that helper). The benchmarks (criterion) are not built or run: they measure, they test nothing.
#
# Two passes, with the default features of zvec-rust (`bundled`, which only changes what the
# build script of zvec-rust-sys may do when the library is not found) and without them.
#
# The tests of the crates were written for zvec v0.8.0-beta2, and the library is v0.8.1: the
# header of the one differs from the other by four functions that the crates do not call, and
# one more that the header had before is not bound either (see the check `abi`, which lists the
# five); the tests show that the rest is as the crates expect.
{
  pkgs,
  src,
  testsLockFile,
}:

let
  inherit (pkgs) lib zvec-c;
  pin = lib.importJSON ../../../pkgs/zvec-rust/pin.json;

  # The test targets of zvec-rust, as its manifest lists them (`autotests` is off: a file in
  # tests/ that is not listed is never built). The check compares them with the manifest it is
  # given, so a target that upstream adds is not run unnoticed.
  targets = [
    "collection_close_test"
    "fts_no_vector_test"
    "integration_test"
    "jieba_fts_test"
    "scalar_query_test"
    "string_filter_test"
  ];

  # The tests in the documentation: seven, of which one is marked `ignore` (it shows a
  # `prelude` that needs a collection), five are compiled and not run (`compile`), and one is
  # `compile_fail`, which passes if it does not compile. They are not counted from the sources,
  # which have no marker for them; this is the list that `cargo test --doc` printed.
  doctests = {
    passed = 6;
    ignored = 1;
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "zvec-rust-tests";
  inherit (pin) version;
  inherit src;
  cargoLock.lockFile = testsLockFile;

  auditable = false;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.jq ];
  # the linker wrapper puts the directory of the library in the RUNPATH of the test programs,
  # which the build script of zvec-rust-sys does not
  buildInputs = [ zvec-c ];

  env = zvec-c.rustEnv // {
    ZVEC_LIB_DIR = "${zvec-c}/lib";
    # test programs without debug information link faster and are a tenth of the size
    CARGO_PROFILE_DEV_DEBUG = "0";
  };

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    export HOME=$TMPDIR
    mkdir -p $TMPDIR/logs

    flags=(--offline -j "$NIX_BUILD_CORES" --target ${pkgs.stdenv.hostPlatform.rust.rustcTargetSpec})
    crates=(-p zvec-rust-sys -p zvec-rust)

    # the lock file this was built with is the one of the repository
    cmp Cargo.lock ${testsLockFile}

    # the test targets of zvec-rust are the ones this check knows
    found="$(cargo metadata --offline --no-deps --format-version 1 \
      | jq -r '.packages[] | select(.name == "zvec-rust") | .targets[] | select(.kind == ["test"]) | .name' | sort | tr '\n' ' ')"
    known="${lib.concatStringsSep " " (lib.sort (a: b: a < b) targets)} "
    [ "$found" = "$known" ] || {
      echo "the manifest lists the test targets: $found" >&2
      echo "this check was written for:           $known" >&2
      exit 1
    }

    # sum of "test result: ok. 12 passed; 0 failed; 1 ignored; ..." over a log
    total() {
      awk -v what="$2" '/^test result: / { for (i = 2; i <= NF; i++) if ($i == what ";") n += $(i - 1) } END { print n + 0 }' "$1"
    }

    # one pass: the unit tests and every test program of both crates (the log is $name.log),
    # and the tests in the documentation (the log is $name.doc.log)
    pass() {
      local name=$1; shift
      cargo test "''${flags[@]}" "''${crates[@]}" --no-fail-fast --lib --tests "$@" -- --nocapture 2>&1 | tee $TMPDIR/logs/$name.log
      cargo test "''${flags[@]}" "''${crates[@]}" --no-fail-fast --doc "$@" 2>&1 | tee $TMPDIR/logs/$name.doc.log
    }
    pass default
    pass nodefault --no-default-features

    # What each pass must come to: no test failed, and those that passed are the #[test]
    # functions of the sources (the lib and the test programs of both crates), less those marked
    # #[ignore]. A test that cannot do what it tests, because the library lacks a feature, says
    # "skipping" and passes: the library here has every feature, so none may say so.
    failed=0
    expect() {
      [ "$2" = "$3" ] || { echo "$1: $2, and this check expects $3" >&2; failed=1; }
    }
    tests="$(grep -rE '^\s*#\[test\]' zvec/src zvec/tests zvec-sys/src zvec-sys/tests | wc -l)"
    ignored="$(grep -rE '^\s*#\[ignore' zvec/src zvec/tests zvec-sys/src zvec-sys/tests | wc -l || true)"
    echo "the sources have $tests #[test] functions, $ignored marked #[ignore]"
    for name in default nodefault; do
      log=$TMPDIR/logs/$name.log
      doc=$TMPDIR/logs/$name.doc.log
      echo "pass $name: $(total $log passed) passed, $(total $log failed) failed, $(total $log ignored) ignored;" \
        "the tests in the documentation: $(total $doc passed) passed, $(total $doc failed) failed, $(total $doc ignored) ignored"
      expect "$name: tests that failed" "$(total $log failed)" 0
      expect "$name: tests that passed" "$(total $log passed)" "$(( tests - ignored ))"
      expect "$name: tests ignored" "$(total $log ignored)" "$ignored"
      expect "$name: tests that skipped themselves" "$(grep -c 'skipping' $log || true)" 0
      expect "$name: documentation tests that failed" "$(total $doc failed)" 0
      expect "$name: documentation tests that passed" "$(total $doc passed)" ${toString doctests.passed}
      expect "$name: documentation tests ignored" "$(total $doc ignored)" ${toString doctests.ignored}
    done
    [ $failed = 0 ] || exit 1

    # Something must be able to fail. A test that expects what the library does not give must
    # fail, and at that test: one that expects two rows of an exact string filter, made to expect three.
    sed -i 's/^        2,$/        3,/' zvec/tests/string_filter_test.rs
    if cmp -s zvec/tests/string_filter_test.rs ${src}/zvec/tests/string_filter_test.rs; then
      echo "the control did not change the test" >&2
      exit 1
    fi
    status=0
    cargo test "''${flags[@]}" -p zvec-rust --test string_filter_test > $TMPDIR/logs/control.log 2>&1 || status=$?
    tail -n 12 $TMPDIR/logs/control.log
    [ $status != 0 ] || { echo "a test that expects what the library does not answer passed" >&2; exit 1; }
    grep -q 'test test_exact_string_filter_returns_matching_rows ... FAILED' $TMPDIR/logs/control.log

    # The library that the tests are linked to is the one that ZVEC_LIB_DIR names, found by the
    # build script of zvec-rust-sys, not by the linker wrapper (which has the directory of the
    # package in NIX_LDFLAGS as well, since the package is an input of the build). Without the
    # variables of the wrapper, the same tests are built with the right directory, and are not
    # with an empty one, and the build script downloads nothing in either case
    # (ZVEC_AUTO_BUILD=0, and the sandbox has no network).
    unwrapped() {
      (
        for v in ''${!NIX_LDFLAGS@}; do unset "$v"; done
        ZVEC_LIB_DIR=$1 cargo test "''${flags[@]}" -p zvec-rust --no-run --test string_filter_test
      )
    }
    unwrapped ${zvec-c}/lib > $TMPDIR/logs/unwrapped.log 2>&1 || { cat $TMPDIR/logs/unwrapped.log; exit 1; }
    mkdir $TMPDIR/empty
    if unwrapped $TMPDIR/empty > $TMPDIR/logs/empty.log 2>&1; then
      echo "the tests were linked with a library directory that has no library" >&2
      exit 1
    fi
    tail -n 6 $TMPDIR/logs/empty.log
    grep -qE 'cannot find -lzvec_c_api|unable to find library -lzvec_c_api' $TMPDIR/logs/empty.log

    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out
    cp $TMPDIR/logs/* $out/
  '';

  meta = {
    description = "The tests of zvec-rust ${pin.version}, run against libzvec_c_api ${zvec-c.version}";
    platforms = [ "x86_64-linux" ];
  };
}
