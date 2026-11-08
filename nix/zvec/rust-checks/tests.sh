# shellcheck shell=bash
# shellcheck disable=SC2154 # the variables are attributes of the derivation
# The tests of zvec-rust-sys and zvec-rust against zvec-c, in four passes (tests.nix). Defines
# rustTestsCheck, the checkPhase. Variables: src, testsLockFile, testTargets, docPassed,
# docIgnored, rustTarget, zvecLib.

# sum of "test result: ok. 12 passed; 0 failed; 1 ignored; ..." over a log
total() {
  awk -v what="$2" '/^test result: / { for (i = 2; i <= NF; i++) if ($i == what ";") n += $(i - 1) } END { print n + 0 }' "$1"
}

# <name> [cargo argument...]: one pass, the unit tests and every test program of both crates (the
# log is <name>.log) and the tests in the documentation (<name>.doc.log), started by `launch` (the
# words that take io_uring away, or nothing). A failed pass is counted, and the others run.
pass() {
  local name=$1
  shift
  if ! "${launch[@]}" cargo test "${flags[@]}" "${crates[@]}" --no-fail-fast --lib --tests "$@" \
    -- --nocapture 2>&1 | tee "$TMPDIR/logs/$name.log"; then
    rustStatus=1
  fi
  if ! "${launch[@]}" cargo test "${flags[@]}" "${crates[@]}" --no-fail-fast --doc "$@" 2>&1 \
    | tee "$TMPDIR/logs/$name.doc.log"; then
    rustStatus=1
  fi
}

# <name> <got> <expected>: counts a difference
expect() {
  [ "$2" = "$3" ] || { nixErrorLog "$1: $2, and this check expects $3"; rustStatus=1; }
}

# The library that the tests are linked to is the one ZVEC_LIB_DIR names, found by the build
# script of zvec-rust-sys, not by the linker wrapper (which has the package in NIX_LDFLAGS too,
# as an input of the build). Without the variables of the wrapper the same tests are built with
# the right directory, and are not with an empty one; the build script downloads nothing in either
# case (ZVEC_AUTO_BUILD=0, and the sandbox has no network).
unwrapped() {
  (
    for v in "${!NIX_LDFLAGS@}"; do unset "$v"; done
    ZVEC_LIB_DIR=$1 cargo test "${flags[@]}" -p zvec-rust --no-run --test string_filter_test
  )
}

rustTestsCheck() {
  runHook preCheck
  set -u
  export HOME=$TMPDIR
  mkdir -p "$TMPDIR/logs"
  rustStatus=0
  flags=(--offline -j "$NIX_BUILD_CORES" --target "$rustTarget")
  crates=(-p zvec-rust-sys -p zvec-rust)

  # the lock file this was built with is the one of the repository
  cmp Cargo.lock "$testsLockFile"

  # the test targets of zvec-rust are the ones this check knows
  found="$(cargo metadata --offline --no-deps --format-version 1 \
    | jq -r '.packages[] | select(.name == "zvec-rust") | .targets[] | select(.kind == ["test"]) | .name' \
    | sort | tr '\n' ' ')"
  if [ "$found" != "$testTargets " ]; then
    nixErrorLog "the manifest lists the test targets: $found; this check was written for: $testTargets"
    exit 1
  fi

  pass default
  pass nodefault --no-default-features
  # with the default features, as the machine has its I/O (default, above) and without io_uring
  # shellcheck disable=SC2329 # called by in_every_mode
  mode_pass() { [ "$1" = default ] || pass "$1"; }
  in_every_mode mode_pass
  launch=()

  # What each pass must come to: no test failed, and those that passed are the #[test] functions
  # of the sources (the lib and the test programs of both crates), less those marked #[ignore]. A
  # test that cannot do what it tests, because the library lacks a feature, says "skipping" and
  # passes: the library here has every feature, so none may say so.
  tests="$(grep -rE '^\s*#\[test\]' zvec/src zvec/tests zvec-sys/src zvec-sys/tests | wc -l)"
  ignored="$(grep -rE '^\s*#\[ignore' zvec/src zvec/tests zvec-sys/src zvec-sys/tests | wc -l || true)"
  echo "the sources have $tests #[test] functions, $ignored marked #[ignore]"
  for name in default nodefault "${modeNames[@]}"; do
    log=$TMPDIR/logs/$name.log
    doc=$TMPDIR/logs/$name.doc.log
    echo "pass $name: $(total "$log" passed) passed, $(total "$log" failed) failed, $(total "$log" ignored) ignored;" \
      "the tests in the documentation: $(total "$doc" passed) passed, $(total "$doc" failed) failed, $(total "$doc" ignored) ignored"
    # the run was under the filter if and only if the mode takes io_uring away
    expect "$name: runs under the filter" "$(grep -c '^no-iouring: ' "$log")" "$([ -v "modeBackend[$name]" ] && echo 1 || echo 0)"
    expect "$name: tests that failed" "$(total "$log" failed)" 0
    expect "$name: tests that passed" "$(total "$log" passed)" "$((tests - ignored))"
    expect "$name: tests ignored" "$(total "$log" ignored)" "$ignored"
    expect "$name: tests that skipped themselves" "$(grep -c 'skipping' "$log" || true)" 0
    expect "$name: documentation tests that failed" "$(total "$doc" failed)" 0
    expect "$name: documentation tests that passed" "$(total "$doc" passed)" "$docPassed"
    expect "$name: documentation tests ignored" "$(total "$doc" ignored)" "$docIgnored"
  done
  [ "$rustStatus" = 0 ] || exit 1

  # Something must be able to fail. A test that expects what the library does not give must fail,
  # at that test: the one that expects two rows of an exact string filter, made to expect three.
  sed -i 's/^        2,$/        3,/' zvec/tests/string_filter_test.rs
  if cmp -s zvec/tests/string_filter_test.rs "$src/zvec/tests/string_filter_test.rs"; then
    nixErrorLog "the control did not change the test"
    exit 1
  fi
  local status=0
  cargo test "${flags[@]}" -p zvec-rust --test string_filter_test >"$TMPDIR/logs/control.log" 2>&1 || status=$?
  tail -n 12 "$TMPDIR/logs/control.log"
  [ "$status" != 0 ] || { nixErrorLog "a test that expects what the library does not answer passed"; exit 1; }
  grep -q 'test test_exact_string_filter_returns_matching_rows ... FAILED' "$TMPDIR/logs/control.log"

  mkdir "$TMPDIR/empty"
  if unwrapped "$TMPDIR/empty" >"$TMPDIR/logs/empty.log" 2>&1; then
    nixErrorLog "the tests were linked with a library directory that has no library"
    exit 1
  fi
  tail -n 6 "$TMPDIR/logs/empty.log"
  grep -qE 'cannot find -lzvec_c_api|unable to find library -lzvec_c_api' "$TMPDIR/logs/empty.log"
  unwrapped "$zvecLib" >"$TMPDIR/logs/unwrapped.log" 2>&1 || { cat "$TMPDIR/logs/unwrapped.log"; exit 1; }
  grep -qE 'Compiling|Linking|Finished' "$TMPDIR/logs/unwrapped.log"

  runHook postCheck
  set +u
}
