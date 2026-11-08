# The test of zvec's C API that zvec itself ships (tests/c/c_api_test.c, with the helpers of
# utils.c), compiled against the installed library the way an application is: the header of
# the package, -lzvec_c_api, no other path to the library than the one the linker records. The
# flags are those of tests/c/CMakeLists.txt: gnu99 (cmake/bazel.cmake: C_STANDARD 99 with
# extensions) and the strict warnings of cc_test (STRICT: -Wall -Wextra -Wshadow-local
# -Wno-misleading-indentation, which upstream turns into errors only with ENABLE_WERROR; the
# test is clean under them with GCC 16, so here they are).
#
# The program is one test framework of its own: it runs the test functions that main calls,
# one after another, prints what each does and a summary, and returns 0 only if every function
# passed. That is not enough to trust, for a program can pass by running too few: so the check
# also reads the functions that main calls from the source and requires the program to have run
# exactly those, by name. Nothing is left out: all of them pass in the sandbox (the tests make
# their directories in the current one and use no network; all that main does with /tmp is to
# glob zvec_test_* there, which finds nothing).
{ pkgs }:

let
  inherit (pkgs) zvec-c;
  inherit (zvec-c) version;
  tests = "${zvec-c.src}/tests/c";
in
pkgs.runCommandCC "zvec-c-tests"
  {
    nativeBuildInputs = [ pkgs.patchelf ];
  }
  ''
    export HOME=$TMPDIR
    # the library is to be found by the path that the linker recorded, and by no other
    unset LD_LIBRARY_PATH
    cd $TMPDIR

    # <source> <program>: the test as upstream builds it
    build() {
      cc -O2 -std=gnu99 -Wall -Wextra -Wshadow-local -Wno-misleading-indentation -Werror \
        -I${tests} -I${zvec-c}/include "$1" ${tests}/utils.c \
        -L${zvec-c}/lib -lzvec_c_api -lm -o "$2"
    }

    build ${tests}/c_api_test.c c_api_test
    patchelf --print-needed c_api_test | grep -qx libzvec_c_api.so
    patchelf --print-rpath c_api_test | tr : '\n' | grep -qx ${zvec-c}/lib

    # The functions that main calls, as the source has them: the test functions are called one to
    # a line, indented, in main, which is the last function of the file. Two functions that the
    # file defines are not among them and are not run: test_performance_benchmarks, which main
    # has commented out, and test_doc_functions, which only calls eight tests that main calls
    # itself.
    sed -n '/^int main(void) {/,$p' ${tests}/c_api_test.c \
      | grep -oE '^ +test_[a-z0-9_]+\(\);' | sed -E 's/^ +//; s/\(\);$//' | sort > called
    expected=$(wc -l < called)
    echo "main calls $expected test functions"
    [ "$expected" -gt 0 ]

    # run in a directory of its own, since the tests make directories (zvec_test_*) in the
    # current one
    mkdir run
    status=0
    (cd run && ../c_api_test) > tests.log 2>&1 || status=$?
    # the log has a line for each of the six thousand assertions that pass; the whole of it is in
    # the output of the check
    grep -v '^  ✓ PASS$' tests.log || true

    [ "$status" = 0 ] || { echo "the test of the C API exited with $status" >&2; exit 1; }
    grep -q '^Failed: 0$' tests.log
    if grep -q '✗ FAIL' tests.log; then
      echo "the test of the C API reported failed assertions" >&2
      exit 1
    fi

    # every function that main calls ran, and nothing else, and the framework's own count agrees
    grep '^Running test: ' tests.log | sed 's/^Running test: //' | sort > ran
    diff called ran
    grep -qx "Total tests: $expected" tests.log
    grep -qx "Passed: $expected" tests.log
    echo "ran $expected tests, $(grep -c '✓ PASS' tests.log) assertions passed, none failed"

    # the library is the version of the package, as the test of its version reads it
    grep -qx '  Version string: v${version}' tests.log
    grep -qx '  Version components: ${version}' tests.log

    # Something must be able to fail. A copy of the test that expects the wrong thing of the
    # library, in the test of the version (it asks whether version 99.99.99 is compatible with
    # this one, and the answer is no), must fail at exactly that assertion and at no other.
    sed 's/TEST_ASSERT(not_compatible == false);/TEST_ASSERT(not_compatible == true);/' \
      ${tests}/c_api_test.c > flipped.c
    if cmp -s ${tests}/c_api_test.c flipped.c; then
      echo "the control was not made: the assertion on the compatibility of versions is not where it was" >&2
      exit 1
    fi
    line=$(grep -n 'TEST_ASSERT(not_compatible == true);' flipped.c | cut -d: -f1)
    build flipped.c flipped
    mkdir control
    status=0
    (cd control && ../flipped) > control.log 2>&1 || status=$?
    grep -E '^Running test: test_version_functions$|FAIL|^(Total|Passed|Failed):' control.log
    [ "$status" != 0 ] || { echo "a test that expects the wrong answer passed" >&2; exit 1; }
    [ "$(grep -c '✗ FAIL' control.log)" = 1 ]
    grep -qx "  ✗ FAIL at line $line" control.log
    grep -qx "Failed: 1" control.log

    # And the program must need the library: without the path that the linker recorded it does
    # not start, and the loader says which library it looked for.
    cp c_api_test no-rpath
    patchelf --remove-rpath no-rpath
    status=0
    ./no-rpath > no-rpath.log 2>&1 || status=$?
    cat no-rpath.log
    [ "$status" != 0 ] || { echo "the test started without the path of the library" >&2; exit 1; }
    grep -q 'libzvec_c_api.so: cannot open shared object file' no-rpath.log

    mkdir $out
    cp tests.log $out/
  ''
