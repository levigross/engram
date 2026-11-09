# What must work with the installed library: found through its CMake package, loading its
# extensions by name, answering a graph query. Each check has something that must fail.
{ pkgs }:

let
  inherit (pkgs) neug;
  extensions = pkgs.lib.escapeShellArgs neug.extensions;
  neugPython = pkgs.python3Packages.callPackage ../../../pkgs/neug/python.nix { };
in
{
  library = pkgs.stdenv.mkDerivation {
    name = "neug-library-check";
    src = ./consumer;
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
    ];
    # the dependencies of the CMake package come with it (propagatedBuildInputs)
    buildInputs = [ neug ];

    doCheck = true;
    checkPhase = ''
      export HOME=$TMPDIR

      # the string_view of abseil is the one NeuG's headers are built against, as the build
      # applied it: a library that disagrees with its headers about it breaks at link time
      grep -q '^#define ABSL_OPTION_USE_STD_STRING_VIEW 0' ${neug}/include/absl/base/options.h

      ./consumer ${extensions} | tee output
      for name in ${extensions}; do
        grep -qi "loaded $name" output
      done
      grep -q 'friend of a friend of Alice: Carol' output

      # LOAD finds the extensions where the library was built to look, which is its own
      # prefix, and nowhere else: pointed at an empty directory it must fail
      mkdir empty
      if NEUG_EXTENSION_HOME_PYENV=$PWD/empty ./consumer parquet >/dev/null 2>&1; then
        echo "LOAD parquet worked with no extensions to load" >&2
        exit 1
      fi
    '';

    installPhase = "touch $out";
  };

  # The addon for Node.js, in the real node of nixpkgs: it loads, opens a database, loads the
  # extensions by name and answers. Without the package on the path of node it must not be
  # found, and a wrong query must throw (the script asserts that).
  nodejs = pkgs.runCommand "neug-nodejs-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    export NODE_PATH=${neug.nodejs}/lib/node_modules
    node ${./node-smoke.js} ${extensions}

    if NODE_PATH= node -e "require('neug')" >/dev/null 2>&1; then
      echo "require('neug') worked without the package on the path" >&2
      exit 1
    fi

    touch $out
  '';

  # The test suite of the addon for Node.js, upstream's own (npm test: tests/test-shim.js forks
  # each test_*.js). Two files open the "modern graph" at /tmp/modern_graph, which upstream's
  # workflow prepares with the helper of the shim first: the same here, in the scratch directory.
  # Nothing is left out. The same runner without the package on the path must fail.
  nodejs-tests = pkgs.runCommand "neug-nodejs-tests" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    cp -r ${neug.src}/tools/nodejs_bind/tests tests
    chmod -R u+w tests
    substituteInPlace tests/test_db_init.js tests/test_db_transaction.js \
      --replace-fail /tmp/modern_graph $TMPDIR/modern_graph

    export NODE_PATH=${neug.nodejs}/lib/node_modules
    export FLEX_DATA_DIR=${neug.src}/example_dataset/modern_graph
    node -e "
      const { Database } = require('neug');
      require('./tests/test-shim').prepareModernGraphDataset(Database, process.env.TMPDIR + '/modern_graph');
    "

    node tests/test-shim.js 2>&1 | tee suite.log
    grep -q "^# file failed: 0" suite.log
    grep -q "^# fail  0" suite.log

    if NODE_PATH= node tests/test-shim.js >/dev/null 2>&1; then
      echo "the suite passed without the package on the path, so it shows nothing" >&2
      exit 1
    fi

    touch $out
  '';

  # Processes forked from one that has drawn a UUID draw the same ones (see fork_uuid.cc), which
  # is why a case of upstream's test suite is left out of cpp-tests. This check holds the fact:
  # it fails when the library no longer does it, and that is the time to put the case back.
  # The control is the same program with a parent that has not drawn: the children differ.
  fork-uuid = pkgs.stdenv.mkDerivation {
    name = "neug-fork-uuid-check";
    dontUnpack = true;
    buildInputs = [ neug ];

    buildPhase = ''
      $CXX -std=c++20 -I${neug}/include ${./fork_uuid.cc} -L${neug}/lib -lneug \
        -Wl,-rpath,${neug}/lib -o fork_uuid
    '';

    doCheck = true;
    checkPhase = ''
      ./fork_uuid seeded | tee seeded.out
      test "$(tail -n1 seeded.out)" = equal

      ./fork_uuid fresh | tee fresh.out
      test "$(tail -n1 fresh.out)" = different
    '';

    installPhase = "touch $out";
  };

  # The C++ test suite of NeuG, upstream's own (about 1300 test cases in about 40 test programs),
  # on the same source, patches and flags as the package with BUILD_TEST on. Upstream runs it as
  # one ctest entry per program ("ctest -R <program>", in .github/workflows), because ctest also
  # lists every case on its own; the same here. The extension tests find the extensions in the
  # build directory, so the extension home built into this build is left unset, as upstream's is.
  #
  # Left out or changed, each with its reason:
  #  - runtime_wait_test, test_http_server and test_db_svc: they are of the transport that the
  #    package does not build (brpc, see pkgs/neug). They include the headers of brpc and bthread
  #    (grep bthread/ and brpc/ in tests/: these three files, and no other): the first is of the
  #    bthread wait of the scheduler, the second drives a brpc channel, the third links brpc and
  #    bthread. The service is covered by test_array_service, and from the outside by the HTTP
  #    check of the Python module.
  #  - HTTPIntegrationTest, a case of httpfs_extension_test: it fetches a file from the network;
  #    its own switch (HTTP_TEST_URL empty) skips it (extension/httpfs/tests/http_test.cc:1036)
  #  - ConnectionReadOnlyTest.ConcurrentProcessesOpenDatabaseSimultaneously, a case of
  #    test_connection: it forks two processes that open one database read-only at the same time.
  #    Both draw the same UUID for the runtime directory they open, the first to close removes it,
  #    and the other fails with "Failed to reserve runtime file ...: No such file or directory"
  #    (the log of the build that left it out). Why they draw the same: the check neug-fork-uuid.
  #    A defect of the library, still in upstream's main (src/utils/uuid.cc, 2026-11-06), and
  #    not of the build. The other 31 cases of test_connection run.
  #  - the two entries of ctest named TEST: CMake's gtest_add_tests reads the C++ files for the
  #    macros of googletest and finds TEST( inside WSHORTEST(weight), a word of a query in a
  #    string (tests/compiler/path_test.cpp, twice). They name no test; the cases themselves,
  #    PathTest.WSHORTEST_PATH and PathTest.WSHORTEST_COST, are in gopt_test, which runs them.
  #
  # Changed: test_array_service sends "parameters":null, and the parser of requests accepts an
  # object only (src/main/query_request.cc:75, "Query parameters must be a JSON object."), so
  # the case fails on any platform; neither the test nor that line is different in upstream's
  # main (2026-11-06) and no workflow of upstream runs the program. It sends {} here, which is
  # what a client sends (RequestSerializer, same file) and what the case is about: arrays.
  #
  # Sized: the two leak tests (test_node_create, test_temporary_tables) do nothing unless
  # NEUG_RUN_MEMORY_LEAK_TESTS=1, and their own sizes are made for a day: with them
  # test_node_create ran 42110 s (11.7 hours, one million single-row CREATEs) and
  # test_temporary_tables 512 s, both passing. They run with the sizes of upstream's scheduled
  # job (.github/workflows/weekly-memory-leak-test.yml: 10 x 10 rows, 100000 bulk rows, 200
  # scans), which it runs weekly with the same binaries.
  cpp-tests = neug.overrideAttrs (old: {
    pname = "neug-cpp-tests";

    postPatch = old.postPatch + ''
      substituteInPlace tests/transaction/CMakeLists.txt \
        --replace-fail 'add_neug_test(runtime_wait_test test_runtime_wait.cc)' ""
      substituteInPlace tests/unittest/CMakeLists.txt \
        --replace-fail 'add_neug_test(test_http_server test_http_server.cc)' "" \
        --replace-fail 'add_neug_test(test_db_svc test_db_svc.cc)' ""
      substituteInPlace tests/unittest/test_array_service.cc \
        --replace-fail '"parameters":null' '"parameters":{}'
    '';

    outputs = [ "out" ];
    postInstall = "";
    # a directory: the fixup writes the propagated inputs of the package into $out/nix-support
    installPhase = "mkdir -p $out";

    cmakeFlags = old.cmakeFlags ++ [
      (pkgs.lib.cmakeBool "BUILD_TEST" true)
      (pkgs.lib.cmakeBool "BUILD_EXECUTABLES" true)
      (pkgs.lib.cmakeBool "BUILD_NODEJS" false)
      # with doCheck, nixpkgs stops passing this, and gflags and glog key on it
      (pkgs.lib.cmakeBool "BUILD_TESTING" false)
      (pkgs.lib.cmakeFeature "NEUG_EXTENSION_HOME" "")
      # googletest is fetched by CMake: the sources of the version it names, no network
      (pkgs.lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_GOOGLETEST" "${neug.googletest}")
      (pkgs.lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    ];

    doCheck = true;
    # the tests use fixed names under /tmp and ports: one at a time
    enableParallelChecking = false;

    checkPhase = ''
      runHook preCheck

      S=$(realpath ..)
      export MODERN_GRAPH_DATA_DIR=$S/example_dataset/modern_graph
      export COMPREHENSIVE_GRAPH_DATA_DIR=$S/example_dataset/comprehensive_graph
      export FLEX_DATA_DIR=$S/example_dataset/modern_graph
      export TEST_PATH=$S/tests
      export TEST_RESOURCE=$S/tests/compiler
      export HTTP_TEST_URL=
      export NEUG_DB_TMP_DIR=$TMPDIR
      # the leak tests, which do nothing without it (tests/memory_leak/test_node_create.cc:53),
      # at the sizes of upstream's scheduled run (see above)
      export NEUG_RUN_MEMORY_LEAK_TESTS=1
      export NEUG_LEAK_OUTER_ITERS=10
      export NEUG_LEAK_INNER_ROWS=10
      export NEUG_LEAK_CHECKPOINT_EVERY=500
      export NEUG_LEAK_BULK_ROWS=100000
      export NEUG_LEAK_SCAN_ITERS=200

      # the two entries named TEST are the words of a query, not tests (see above): there are
      # two, and the cases they stand next to are in the program that runs them
      test "$(ctest -N | grep -c ': TEST$')" = 2
      test "$(tests/compiler/gopt_test --gtest_list_tests | grep -c '^  WSHORTEST_')" = 2

      # the test programs: the entries of ctest that are not a case of one (those have a dot)
      programs=$(ctest -N | sed -n 's/^ *Test *#[0-9]*: //p' | grep -v '\.' \
        | grep -vx -e TEST -e test_connection -e test_extension | sort -u | paste -sd'|')
      echo "programs: $(echo "$programs" | tr '|' '\n' | wc -l)"
      ctest -j1 --output-on-failure --no-tests=error -R "^($programs)$"

      # this one reads another dataset
      FLEX_DATA_DIR=$S/example_dataset/tinysnb ctest --output-on-failure --no-tests=error -R '^test_extension$'

      # all of it but the one case (see above)
      GTEST_FILTER=-ConnectionReadOnlyTest.ConcurrentProcessesOpenDatabaseSimultaneously \
        ctest -V --no-tests=error -R '^test_connection$' | tee connection.log
      grep -q '\[  PASSED  \] 31 tests' connection.log

      runHook postCheck
    '';
  });
}
# the Python module is not offered for a nixpkgs whose protobuf is not the one it requires
// pkgs.lib.optionalAttrs (import ../python-supported.nix pkgs) {
  # The Python module, in the Python of nixpkgs: it imports, opens a database, loads the
  # extensions by name from the prefix of the library, and answers. The same script in a
  # Python that has everything but the module must fail, and so must LOAD where the module
  # is told that there are no extensions.
  python =
    let
      withNeug = pkgs.python3.withPackages (_: [ neugPython ]);
      without = pkgs.python3.withPackages (ps: [
        ps.packaging
        ps.protobuf5
        ps.requests
      ]);
    in
    pkgs.runCommand "neug-python-check" { } ''
      export HOME=$TMPDIR
      cd $TMPDIR

      ${withNeug}/bin/python ${./python-smoke.py} ${neug}/lib ${extensions}

      if ${without}/bin/python ${./python-smoke.py} ${neug}/lib ${extensions} >/dev/null 2>&1; then
        echo "the script worked without the module, so this check shows nothing" >&2
        exit 1
      fi

      mkdir empty
      ${withNeug}/bin/python ${./python-load.py} parquet >/dev/null
      if NEUG_EXTENSION_HOME_PYENV=$PWD/empty ${withNeug}/bin/python ${./python-load.py} parquet >/dev/null 2>&1; then
        echo "LOAD parquet worked with no extensions to load" >&2
        exit 1
      fi

      touch $out
    '';

  # The service mode (Database.serve, an HTTP server) through the module. The interpreter
  # loads libneug with dlopen, so its thread-locals are in dynamic TLS, and the server of
  # upstream's Linux build (brpc) crashed in a worker thread a second after serve() with them,
  # in the compiler that makes TLS descriptors (docs/neug.md has the evidence). The package
  # serves over cpp-httplib instead. python-serve-repro.py is the script that showed the crash
  # (a segmentation fault, status 139). python-serve.py asks the server a query with plain HTTP
  # requests, compares the answer, asks what the transport must do as brpc did (a path that
  # starts with two slashes is routed, 200 requests on one connection take under 2.5 s) and
  # stops it. Both must end with status 0 within the time limit, so a crash or a hang fails.
  # The same client where no server listens must fail.
  python-serve =
    let
      withNeug = pkgs.python3.withPackages (_: [ neugPython ]);
    in
    pkgs.runCommand "neug-python-serve-check" { } ''
      export HOME=$TMPDIR
      cd $TMPDIR

      timeout 120 ${withNeug}/bin/python ${./python-serve-repro.py}
      timeout 120 ${withNeug}/bin/python ${./python-serve.py} serve

      port=$(${withNeug}/bin/python -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
      if timeout 60 ${withNeug}/bin/python ${./python-serve.py} ask http://127.0.0.1:$port >/dev/null 2>&1; then
        echo "the client got an answer where no server listens, so this check shows nothing" >&2
        exit 1
      fi

      touch $out
    '';

  # The test suite of the Python module, upstream's own, on the installed module, offline (the
  # file says what is left out and why)
  python-tests = import ./python-tests.nix { inherit pkgs neug neugPython; };
}
