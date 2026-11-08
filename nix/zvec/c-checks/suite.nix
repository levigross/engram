# zvec's own unit tests, upstream's, run for the library of pkgs/zvec-c: the same source,
# patches and flags as the package, with the test programs of some directories of tests/ built
# and run by ctest (the targets of the tests are not part of the default build). Called for the
# libraries that need no Arrow (ailego, core, turbo) and for the database layer (db).
{
  pkgs,
  # what the check is called, and the directories of tests/ it runs
  name,
  dirs,
  # targets that are not tests but that tests need (programs that they start)
  extraTargets ? [ ],
  # a ctest pattern for tests that must not run at the same time as others (they kill processes
  # and wait for time to pass), which run last, one by one
  serial ? null,
  # test files that CMake does not register as a test on this system, with the reason (the files
  # are the evidence: it is a condition of the CMakeLists.txt next to them)
  notRegistered ? [ ],
  # the tests that skip themselves, as they print it: gtest's "[  SKIPPED ] Suite.Test". Each
  # is there for a reason that the source of the test gives, which the comment next to the list
  # says; a test that skips itself for another reason, or does not any more, fails the check
  skipped ? [ ],
  # environment variables for the tests (to turn on what a test asks for before it runs)
  env ? { },
  # directories of libraries that the tests may load besides their own (a library that zvec
  # opens with dlopen and that the package does not provide)
  libraryPath ? [ ],
  # Something must be able to fail: this test file is changed so that one expectation is wrong,
  # its program built again, and it must fail
  control,
}:

let
  inherit (pkgs) lib zvec-c;
in
zvec-c.overrideAttrs (old: {
  pname = "zvec-c-${name}-tests";
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
    # the tests that CMake registered, which is every test file there is but those it does not
    # build on this system (see notRegistered)
    for d in ${lib.concatStringsSep " " dirs}; do
      ninjaFlagsArray+=( $(ctest --test-dir tests/$d -N | sed -n 's/^ *Test *#[0-9]*: //p') )
    done
    ninjaFlagsArray+=( ${lib.escapeShellArgs extraTargets} )
  '';

  checkPhase = ''
    runHook preCheck
    export LD_LIBRARY_PATH=${
      lib.concatStringsSep ":" ([ "$PWD/lib" ] ++ map (p: "${p}/lib") libraryPath)
    }
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "export ${n}=${lib.escapeShellArg v}") env)}
    mkdir -p $TMPDIR/logs

    # every directory is run before the check fails, to see all that fails
    status=0
    for d in ${lib.concatStringsSep " " dirs}; do
      # the tests that ctest knows are the test files there are, but those that CMake does not
      # register on this system, so that a test left out of the build is not left out unnoticed
      find ../tests/$d -name '*_test.cc' -printf '%f\n' | sed 's/\.cc$//' | sort -u > $TMPDIR/files.$d
      ctest --test-dir tests/$d -N | sed -n 's/^ *Test *#[0-9]*: //p' | sort -u > $TMPDIR/registered.$d
      comm -23 $TMPDIR/files.$d $TMPDIR/registered.$d > $TMPDIR/not-registered.$d
      echo "=== $d: $(wc -l < $TMPDIR/registered.$d) tests, $(wc -l < $TMPDIR/files.$d) test files," \
        "not registered: $(tr '\n' ' ' < $TMPDIR/not-registered.$d)"
      if [ -s $TMPDIR/not-registered.$d ]; then
        # (each directory has its own: the pattern keeps the ones of the other directories out)
        grep -vxF -f <(printf '%s\n' ${lib.escapeShellArgs notRegistered}) $TMPDIR/not-registered.$d && {
          echo "$d: test files that CMake does not register, and that this check does not know" >&2
          status=1
        }
      fi
      if [ -n "$(comm -13 $TMPDIR/files.$d $TMPDIR/registered.$d)" ]; then
        echo "$d: tests that are registered and have no file of that name:" >&2
        comm -13 $TMPDIR/files.$d $TMPDIR/registered.$d >&2
        status=1
      fi
      ${
        if serial == null then
          ''
            ctest --test-dir tests/$d -j"$((NIX_BUILD_CORES / 2 + 1))" --timeout 1500 --output-on-failure \
              --no-tests=error -V > $TMPDIR/logs/$d.log 2>&1 || status=1
          ''
        else
          ''
            ctest --test-dir tests/$d -j"$((NIX_BUILD_CORES / 2 + 1))" --timeout 1500 --output-on-failure \
              --no-tests=error -V -E '${serial}' > $TMPDIR/logs/$d.log 2>&1 || status=1
            ctest --test-dir tests/$d -j1 --timeout 1500 --output-on-failure \
              --no-tests=error -V -R '${serial}' > $TMPDIR/logs/$d.serial.log 2>&1 || status=1
          ''
      }
      tail -n 4 $TMPDIR/logs/$d.log
    done
    grep -h 'tests passed' $TMPDIR/logs/*.log || true
    if [ $status != 0 ]; then
      grep -h -B2 -A12 -E '\*\*\*Failed|\*\*\*Timeout|\*\*\*Exception|Test +#[0-9]+: .*\.\.\.+ *(Failed|\*)' $TMPDIR/logs/*.log | tail -n 150
      exit 1
    fi

    # the tests that skipped themselves are the ones this check knows
    # (ctest -V puts the number of the test in front of every line it prints: "23: [  SKIPPED ]")
    sed -n 's/^[0-9]*: \[  SKIPPED \] \([A-Za-z0-9_]*\.[A-Za-z0-9_/]*\).*/\1/p' $TMPDIR/logs/*.log | sort -u > $TMPDIR/skipped
    printf '%s\n' ${lib.escapeShellArgs skipped} | sed '/^$/d' | sort -u > $TMPDIR/skipped.expected
    echo "skipped by themselves: $(wc -l < $TMPDIR/skipped)"
    # the pattern above must see what the logs say: a log that mentions a skip and a pattern
    # that finds none would be a check that cannot fail
    if grep -qh 'SKIPPED \]' $TMPDIR/logs/*.log && [ ! -s $TMPDIR/skipped ]; then
      echo "the logs have tests that were skipped, and the pattern that finds them found none" >&2
      exit 1
    fi
    diff $TMPDIR/skipped.expected $TMPDIR/skipped

    # The control: with one expectation made wrong, the test program built again must fail
    sed -i 's/${control.from}/${control.to}/' ../${control.file}
    if cmp -s ../${control.file} ${
      pkgs.runCommand "original" { } "cp ${zvec-c.src}/${control.file} $out"
    }; then
      echo "the control did not change the test" >&2
      exit 1
    fi
    ninja ${control.target}
    if ctest --test-dir tests/${control.dir} -R '^${control.target}$' --output-on-failure > $TMPDIR/logs/control.log 2>&1; then
      cat $TMPDIR/logs/control.log
      echo "a test with a wrong expectation passed" >&2
      exit 1
    fi
    tail -n 12 $TMPDIR/logs/control.log
    grep -q '\[  FAILED  \]' $TMPDIR/logs/control.log

    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out
    cp $TMPDIR/logs/*.log $out/
  '';

  meta = old.meta // {
    description = "The unit tests of zvec (${lib.concatStringsSep ", " dirs}), run for the library of zvec-c";
  };
})
