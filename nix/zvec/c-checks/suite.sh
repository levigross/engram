# shellcheck shell=bash
# shellcheck disable=SC2154 # the variables are attributes of the derivation
# zvec's unit tests, run by ctest in every mode of the I/O (../io/modes.sh), for the build of
# pkgs/zvec-c that has the test programs of some directories of tests/. Defines suitePreBuild and
# suiteCheck, which suite.nix makes the preBuild hook and the checkPhase.
#
# Attributes: dirs, extraTargets, serial, notRegistered, flaky, expectedSkips (the file of the
# tests that skip themselves, by mode), control{File,From,To,Target,Dir}.

# the tests that CMake registered, which is every test file there is but those it does not build
# on this system (notRegistered)
suitePreBuild() {
  local d
  for d in "${dirs[@]}"; do
    # shellcheck disable=SC2207 # test names have no spaces
    ninjaFlagsArray+=($(ctest --test-dir "tests/$d" -N | sed -n 's/^ *Test *#[0-9]*: //p'))
  done
  ninjaFlagsArray+=("${extraTargets[@]}")
}

# the tests that failed in a log of ctest, which lists them as "   35 - name (Failed)"
failed_tests() {
  sed -n 's/^[[:space:]]*[0-9][0-9]* - \(.*\) ([^()]*)$/\1/p' "$1" | sort -u
}

# <dir> <logs>: when every test that failed is known to fail now and then (flaky), run those
# again, three times at most each, and say so. Fails if another test failed, or one fails every
# time. The first run stays in <dir>.log, the others are in <dir>.retry.log.
retry_flaky() {
  local d=$1 logs=$2 failed rc=0
  failed="$(failed_tests "$logs/$d.log")"
  [ -n "$failed" ] || return 1
  # ctest counts the tests that failed: every one of them has been parsed
  [ "$(wc -l <<<"$failed")" = "$(sed -n 's/.* \([0-9][0-9]*\) tests failed out of .*/\1/p' "$logs/$d.log")" ] || return 1
  if printf '%s\n' "$failed" | grep -qvxF -f <(printf '%s\n' "${flaky[@]}"); then
    return 1
  fi
  echo "$d: only tests that are known to fail now and then failed ($(tr '\n' ' ' <<<"$failed"))," \
    "running them again, 3 times at most each"
  "${launch[@]}" ctest --test-dir "tests/$d" -R "^($(paste -sd'|' <<<"$failed"))\$" -j1 \
    --repeat until-pass:3 --timeout 1500 --output-on-failure --no-tests=error -V \
    >"$logs/$d.retry.log" 2>&1 || rc=$?
  grep -E '^[0-9]+/[0-9]+ Test +#' "$logs/$d.retry.log" || true
  return $rc
}

# <mode>: the directories of the suite; the logs are in logs/<mode>. Sets suiteStatus to 1 on a
# failure, after all directories have run.
run_suite() {
  local logs=$TMPDIR/logs/$1 d only=()
  mkdir -p "$logs"
  # the tests that must not run next to others (they kill processes and wait for time to pass)
  # run last, one at a time
  [ -z "$serial" ] || only=(-E "$serial")
  for d in "${dirs[@]}"; do
    echo "--- run: $d, $1"
    "${launch[@]}" ctest --test-dir "tests/$d" -j"$((NIX_BUILD_CORES / 2 + 1))" --timeout 1500 \
      --output-on-failure --no-tests=error -V "${only[@]}" >"$logs/$d.log" 2>&1 \
      || retry_flaky "$d" "$logs" || suiteStatus=1
    if [ -n "$serial" ]; then
      "${launch[@]}" ctest --test-dir "tests/$d" -j1 --timeout 1500 --output-on-failure \
        --no-tests=error -V -R "$serial" >"$logs/$d.serial.log" 2>&1 || suiteStatus=1
    fi
    tail -n 4 "$logs/$d.log"
  done
  grep -h 'tests passed' "$logs"/*.log || true
}

# the whole output of every test that failed (ctest -V puts the number of the test in front of
# each line; the list "The following tests FAILED" has "35 - name (Failed)")
report_failures() {
  local log n
  for log in "$TMPDIR"/logs/*/*.log; do
    while read -r n; do
      echo "=== ${log#"$TMPDIR/logs/"}, test $n"
      grep -E "^$n: " "$log" | tail -n 80 || true
    done < <(sed -n 's/^[[:space:]]*\([0-9][0-9]*\) - .* ([^()]*)$/\1/p' "$log" | sort -un)
  done
}

# <mode>: the tests that skipped themselves in the mode are the ones expected for it (ctest -V
# puts the number of the test in front of every line it prints: "23: [  SKIPPED ]")
check_skips() {
  local dir=$TMPDIR/logs/$1
  sed -n 's/^[0-9]*: \[  SKIPPED \] \([^ ]*\.[^ ]*\).*/\1/p' "$dir"/*.log | sort -u >"skipped.$1"
  sort -u "${expectedSkips[$1]}" >"skipped.expected.$1"
  echo "skipped by themselves, $1: $(wc -l <"skipped.$1")"
  # a log that mentions a skip and a pattern that finds none would be a check that cannot fail
  if grep -qh 'SKIPPED \]' "$dir"/*.log && [ ! -s "skipped.$1" ]; then
    nixErrorLog "the logs have tests that were skipped, and the pattern that finds them found none"
    exit 1
  fi
  diff "skipped.expected.$1" "skipped.$1"
}

# <mode>: the library says when it has neither io_uring nor libaio, in each process that uses
# DiskANN (diskann_file_reader.cc:57). That is so where libaio cannot be loaded and not where it
# can; "default" has whatever the machine has.
check_backend_warning() {
  local dir=$TMPDIR/logs/$1 warning='DiskAnn: no async I/O backend available'
  local log
  # the runs were under the filter if and only if the mode takes io_uring away
  for log in "$dir"/*.log; do
    case "$log" in *.retry.log | */control.log) continue ;; esac
    if [ -v "modeBackend[$1]" ]; then
      grep -q '^no-iouring: ' "$log" || { nixErrorLog "$1: ${log##*/} was not run under the filter"; exit 1; }
    elif grep -q '^no-iouring: ' "$log"; then
      nixErrorLog "$1: ${log##*/} was run under the filter"
      exit 1
    fi
  done
  case "${modeBackend[$1]:-}" in
    pread)
      grep -qh "$warning" "$dir"/*.log \
        || { nixErrorLog "$1: the tests did not log that the library has no async I/O backend"; exit 1; }
      ;;
    "") ;;
    *)
      if grep -qh "$warning" "$dir"/*.log; then
        nixErrorLog "$1: the tests logged that the library has no async I/O backend"
        exit 1
      fi
      ;;
  esac
}

suiteCheck() {
  runHook preCheck
  set -u
  mkdir -p "$TMPDIR/logs"
  suiteStatus=0
  libraryBase=$PWD/lib

  # every directory is run before the check fails, to see all that fails. First the tests that
  # ctest knows must be the test files there are, but those that CMake does not register on this
  # system, so that a test left out of the build is not left out unnoticed.
  local d
  for d in "${dirs[@]}"; do
    find ../tests/"$d" -name '*_test.cc' -printf '%f\n' | sed 's/\.cc$//' | sort -u >"$TMPDIR/files.$d"
    ctest --test-dir "tests/$d" -N | sed -n 's/^ *Test *#[0-9]*: //p' | sort -u >"$TMPDIR/registered.$d"
    comm -23 "$TMPDIR/files.$d" "$TMPDIR/registered.$d" >"$TMPDIR/not-registered.$d"
    echo "=== $d: $(wc -l <"$TMPDIR/registered.$d") tests, $(wc -l <"$TMPDIR/files.$d") test files," \
      "not registered: $(tr '\n' ' ' <"$TMPDIR/not-registered.$d")"
    if grep -vxF -f <(printf '%s\n' "${notRegistered[@]}") "$TMPDIR/not-registered.$d"; then
      nixErrorLog "$d: test files that CMake does not register, and that this check does not know"
      suiteStatus=1
    fi
    if [ -n "$(comm -13 "$TMPDIR/files.$d" "$TMPDIR/registered.$d")" ]; then
      nixErrorLog "$d: tests that are registered and have no file of that name:"
      comm -13 "$TMPDIR/files.$d" "$TMPDIR/registered.$d" >&2
      suiteStatus=1
    fi
  done

  in_every_mode run_suite
  if [ "$suiteStatus" != 0 ]; then
    report_failures
    exit 1
  fi
  in_every_mode check_skips
  in_every_mode check_backend_warning

  # Something must be able to fail: with one expectation made wrong, the test program built
  # again must fail
  export LD_LIBRARY_PATH=$libraryBase
  substituteInPlace "../$controlFile" --replace-fail "$controlFrom" "$controlTo"
  ninja "$controlTarget"
  local log=$TMPDIR/logs/default/control.log
  if ctest --test-dir "tests/$controlDir" -R "^$controlTarget\$" --output-on-failure >"$log" 2>&1; then
    cat "$log"
    nixErrorLog "a test with a wrong expectation passed"
    exit 1
  fi
  tail -n 12 "$log"
  grep -q '\[  FAILED  \]' "$log"

  runHook postCheck
  set +u
}
