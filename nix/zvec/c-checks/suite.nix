# zvec's own unit tests, upstream's, for the library of pkgs/zvec-c: the same source, patches and
# flags, with the test programs of some directories of tests/ built and run by ctest (they are
# not part of the default build). The suite runs in every mode of the I/O, as the machine has it
# and without io_uring (../io), and has to pass in all. Called for the libraries that need no
# Arrow (ailego, core, turbo) and for the database layer (db).
{
  pkgs,
  io,
  # what the check is called, and the directories of tests/ it runs
  name,
  dirs,
  # targets that are not tests but that tests need (programs that they start)
  extraTargets ? [ ],
  # a ctest pattern for the tests that must not run at the same time as others, which run last
  serial ? "",
  # test files that CMake does not register as a test on this system (docs/zvec.md#other-tests-and-programs-not-run)
  notRegistered ? [ ],
  # The tests that skip themselves ("[  SKIPPED ] Suite.Test") in every mode, and in the modes
  # without io_uring besides (by mode name, as in ../io). A test that skips itself for another
  # reason, or does not any more, fails the check. Some tests skip for want of an instruction set,
  # so the list is that of an x86_64 CPU with AVX-512 and VNNI, built as an unprivileged user.
  skipped ? [ ],
  skippedIn ? { },
  # tests that fail now and then on their first run, for no reason in the package: run again,
  # three times at most, when they are the only ones to fail (docs/zvec.md#a-test-that-fails-on-its-first-run)
  flaky ? [ ],
  # environment variables for the tests
  env ? { },
  # libraries that the tests may open with dlopen, besides their own, in the default mode
  libraries ? [ ],
  # Something must be able to fail: in this file, `from` is changed to `to`, the test program
  # `target` of directory `dir` is built again, and it must fail
  control,
}:

let
  inherit (pkgs) lib zvec-c;

  # a mode that is not in ../io has no effect: a name wrong here would go unnoticed
  unknownModes = lib.filter (m: !(io.modes ? ${m})) (lib.attrNames skippedIn);

  skipFile =
    mode: names: pkgs.writeText "zvec-c-${name}-skipped-${mode}" (lib.concatLines (lib.unique names));
in
assert lib.assertMsg (
  unknownModes == [ ]
) "skippedIn names modes that do not exist: ${toString unknownModes}";
zvec-c.overrideAttrs (old: {
  pname = "zvec-c-${name}-tests";
  doCheck = true;
  dontFixup = true;

  nativeBuildInputs = old.nativeBuildInputs ++ [
    (io.hook libraries)
    (pkgs.makeSetupHook { name = "zvec-suite-hook"; } ./suite.sh)
  ];
  env = old.env // env;

  inherit
    dirs
    extraTargets
    serial
    notRegistered
    flaky
    ;
  expectedSkips = {
    default = skipFile "default" skipped;
  }
  // lib.mapAttrs (mode: _: skipFile mode (skipped ++ skippedIn.${mode} or [ ])) io.modes;
  controlFile = control.file;
  controlFrom = control.from;
  controlTo = control.to;
  controlTarget = control.target;
  controlDir = control.dir;

  # the targets are the test programs, named like their files (suitePreBuild)
  ninjaFlags = [ ];
  preBuild = "suitePreBuild";
  checkPhase = "suiteCheck";
  installPhase = ''
    mkdir -p $out
    cp -r $TMPDIR/logs/* $out/
  '';

  # the googletest of zvec (1.10.0) uses uintptr_t without including <cstdint>, which GCC 15
  # and later no longer let pass
  postPatch = (old.postPatch or "") + ''
    substituteInPlace thirdparty/googletest/googletest-1.10.0/googletest/src/gtest-death-test.cc \
      --replace-fail '# include <limits.h>' '# include <limits.h>
    # include <cstdint>'
  '';

  meta = old.meta // {
    description = "The unit tests of zvec (${lib.concatStringsSep ", " dirs}), run for the library of zvec-c";
  };
})
