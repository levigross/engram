# The I/O of zvec's library on a kernel without io_uring, for the checks: a wrapper that takes
# io_uring away from a program, the modes that follow, and a setup hook with which a check runs
# in each of them. See docs/zvec.md#without-io_uring.
#
# The library uses io_uring if it can make a ring, otherwise libaio if dlopen finds it, otherwise
# pread. Nothing in zvec-c provides libaio, so it is found only where a mode puts it on the
# library path.
{ pkgs }:

let
  inherit (pkgs) lib zvec-c;

  no-iouring = pkgs.runCommandCC "no-iouring" { buildInputs = [ pkgs.libseccomp ]; } ''
    mkdir -p $out/bin
    cc -O2 -Wall -Wextra -o $out/bin/no-iouring ${./no_iouring.c} -lseccomp
  '';

  # prints which backend the library selects
  probe = pkgs.runCommandCC "zvec-c-io-probe" { } ''
    mkdir -p $out/bin
    cc -O2 -Wall -Wextra -I${zvec-c}/include -o $out/bin/io-probe ${./io_probe.c} \
      -L${zvec-c}/lib -lzvec_c_api
  '';

  # Besides "default", the I/O the machine has. The errors differ so that both are exercised.
  modes = {
    libaio = {
      errno = "ENOSYS";
      libraries = [ pkgs.libaio ];
      backend = "libaio";
      description = "libaio async I/O backend loaded at runtime";
    };
    pread = {
      errno = "EPERM";
      libraries = [ ];
      backend = "pread";
      description = "io_uring is unavailable and libaio could not be loaded";
    };
  };
in
{
  inherit no-iouring probe modes;

  # A setup hook (for nativeBuildInputs) with the modes as shell variables and `in_every_mode`
  # (modes.sh). `libraries` are on the library path in "default".
  hook =
    libraries:
    pkgs.makeSetupHook { name = "zvec-io-modes-hook"; } (
      pkgs.concatText "zvec-io-modes.sh" [
        (pkgs.writeText "zvec-io-modes-data.sh" (
          # (setup hooks are sourced in a function: `declare` would make the variables local)
          lib.replaceStrings [ "declare -A " "declare -a " ] [ "declare -gA " "declare -ga " ] (
            lib.toShellVars {
              modeNames = lib.attrNames modes;
              modeLaunch = lib.mapAttrs (_: m: "${no-iouring}/bin/no-iouring --errno ${m.errno}") modes;
              modeLibraries = {
                default = lib.makeLibraryPath libraries;
              }
              // lib.mapAttrs (_: m: lib.makeLibraryPath m.libraries) modes;
              modeBackend = lib.mapAttrs (_: m: m.backend) modes;
              modeDescription = lib.mapAttrs (_: m: m.description) modes;
              ioProbe = "${probe}/bin/io-probe";
              noIouring = "${no-iouring}/bin/no-iouring";
            }
          )
          + "\n"
        ))
        ./modes.sh
      ]
    );
}
