# shellcheck shell=bash
# shellcheck disable=SC2154 # the variables are attributes of the derivation
# zvec's own test of the C API (tests/c/c_api_test.c), compiled against the installed library
# the way an application is and run in every mode of the I/O (../io/modes.sh).
# Attributes: zvecC (the package), tests (the directory tests/c of its source).
set -u
export HOME=$TMPDIR
cd "$TMPDIR" || exit

# <source> <program>: the test as upstream builds it
build() {
  cc -O2 -std=gnu99 -Wall -Wextra -Wshadow-local -Wno-misleading-indentation -Werror \
    -I"$tests" -I"$zvecC/include" "$1" "$tests/utils.c" \
    -L"$zvecC/lib" -lzvec_c_api -lm -o "$2"
}

build "$tests/c_api_test.c" c_api_test
patchelf --print-needed c_api_test | grep -qx libzvec_c_api.so
patchelf --print-rpath c_api_test | tr : '\n' | grep -qx "$zvecC/lib"

# The functions that main calls: one to a line, indented, in main, the last function of the
# file. test_performance_benchmarks (commented out in main) and test_doc_functions (which only
# calls eight tests that main calls itself) are defined and not run.
sed -n '/^int main(void) {/,$p' "$tests/c_api_test.c" \
  | grep -oE '^ +test_[a-z0-9_]+\(\);' | sed -E 's/^ +//; s/\(\);$//' | sort >called
expected=$(wc -l <called)
echo "main calls $expected test functions"
[ "$expected" -gt 0 ]

# <mode>: the test, in a directory of its own (it makes directories zvec_test_* in the current
# one), and what must come of it
run_tests() {
  local log=tests.$1.log status=0
  mkdir "run-$1"
  (cd "run-$1" && "${launch[@]}" ../c_api_test) >"$log" 2>&1 || status=$?
  # the run was under the filter if and only if the mode takes io_uring away
  if [ "$1" = default ]; then
    ! grep -q '^no-iouring: ' "$log" || { nixErrorLog "$1: the run was under the filter"; exit 1; }
  else
    grep -q '^no-iouring: ' "$log" || { nixErrorLog "$1: the run was not under the filter"; exit 1; }
  fi
  # a line for each of the six thousand assertions that pass
  grep -v '^  ✓ PASS$' "$log" || true

  [ "$status" = 0 ] || { nixErrorLog "the test exited with $status"; exit 1; }
  grep -q '^Failed: 0$' "$log"
  if grep -q '✗ FAIL' "$log"; then
    nixErrorLog "the test reported failed assertions"
    exit 1
  fi

  # every function that main calls ran, and nothing else, and the framework's count agrees
  grep '^Running test: ' "$log" | sed 's/^Running test: //' | sort >ran
  diff called ran
  grep -qx "Total tests: $expected" "$log"
  grep -qx "Passed: $expected" "$log"
  [ "$(grep -c '✓ PASS' "$log")" -gt 0 ] || { nixErrorLog "no assertion passed"; exit 1; }
  echo "$1: ran $expected tests, $(grep -c '✓ PASS' "$log") assertions passed, none failed"

  # the library is the version of the package
  grep -qx "  Version string: v$version" "$log"
  grep -qx "  Version components: $version" "$log"
}
in_every_mode run_tests

# Something must be able to fail. A copy that expects the wrong answer in the test of the
# version (is 99.99.99 compatible with this one? no) must fail at that assertion and no other.
substitute "$tests/c_api_test.c" flipped.c \
  --replace-fail 'TEST_ASSERT(not_compatible == false);' 'TEST_ASSERT(not_compatible == true);'
[ "$(grep -c 'TEST_ASSERT(not_compatible == true);' flipped.c)" = 1 ]
line=$(grep -n 'TEST_ASSERT(not_compatible == true);' flipped.c | cut -d: -f1)
unset LD_LIBRARY_PATH
build flipped.c flipped
mkdir control
status=0
(cd control && ../flipped) >control.log 2>&1 || status=$?
grep -E '^Running test: test_version_functions$|FAIL|^(Total|Passed|Failed):' control.log
[ "$status" != 0 ] || { nixErrorLog "a test that expects the wrong answer passed"; exit 1; }
[ "$(grep -c '✗ FAIL' control.log)" = 1 ]
grep -qx "  ✗ FAIL at line $line" control.log
grep -qx "Failed: 1" control.log

# The program needs the library: without the path the linker recorded it does not start.
cp c_api_test no-rpath
patchelf --remove-rpath no-rpath
status=0
./no-rpath >no-rpath.log 2>&1 || status=$?
cat no-rpath.log
[ "$status" != 0 ] || { nixErrorLog "the test started without the path of the library"; exit 1; }
grep -q 'libzvec_c_api.so: cannot open shared object file' no-rpath.log

mkdir "$out"
cp tests.*.log "$out/"
